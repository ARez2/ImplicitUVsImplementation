#[compute]
#version 450

const int MAX_MARCHING_STEPS = 100;
const float MIN_DIST = 0.001;
const float MAX_DIST = 100.0;
const float EPSILON = 0.001;
const float FLOAT_INF = 1.0 / 0.0;
const int MAX_NUM_OBJECTS = 16;
const int SDF_MODE_UNION = 1;
const int SDF_MODE_DIFFERENCE = 2;
const int SDF_MODE_INTERSECT = 3;
const int MESH_TYPE_SPHERE = 1;
const int MESH_TYPE_CUBE = 2;
const int MESH_TYPE_CYLINDER = 3;
const int MESH_TYPE_TORUS = 4;
const float TAU = 6.2831853071795864769252867665590;

// Invocations in the (x, y, z) dimension
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba32f, set = 0, binding = 0) uniform restrict writeonly image2D write_image;
// 2x mat4 per primitive:
// - 1st mat4 = transform (where mat4[0-2] = x-z basis, mat4[3] = position)
// - 2nd mat4 = (vec3(mesh_type, sdf_mode, blending), vec3(mesh params), vec3(0), vec3(0))
const int NUM_MATRICES_PER_OBJ = 2;
layout(set = 0, binding = 1, std430) restrict buffer MySceneData {
    int num_scene_objects;
    mat4 data[MAX_NUM_OBJECTS * NUM_MATRICES_PER_OBJ];
} scene_data;
layout(set = 0, binding = 2, std140) uniform CameraData {
    mat4 inv_projection_matrix;
    mat4 view_matrix;
} camera_data;
layout(set = 0, binding = 4) uniform sampler2D color_tex;

// Push constants have a max size of 128 bytes (32 floats).
layout(push_constant, std430) uniform Params {
    vec2 ViewportSize;
    float GlobalBlending;

    float AlbedoBlendOffset;
    vec3 CamPosWorld;
    // float AlbedoBlendPower;
    float Time;
    // The sigma used for the blending width
    float ImplicitUVsBlending;
    // 0 = nothing, 1 = frames, 2 = offsets
    int PrecalcStage;
} params;

// Prevent the quad from being affected by lighting and fog. This also improves performance.
#include "sdf_functions.glsl"

// vec4(pt, 1.0) = position, vec4(pt, 0.0) = direction
vec3 transform(vec3 v, mat4 trans, float pt_or_dir) {
    return (trans * vec4(v, pt_or_dir)).xyz;
}
vec3 transform_point(vec3 pt, mat4 trans) {
    return transform(pt, trans, 1.0);
}
vec3 transform_dir(vec3 dir, mat4 trans) {
    return transform(dir, trans, 0.0);
}

struct HitInfo {
    float depth;
    int last_obj_hit;
    int second_last_obj_hit;
    float blend_between_objs;
};

// Returns vec4: x = depth, y = last object hit, z = 2nd last object hit, w = blend between hit objects
HitInfo sceneSDF(vec3 sample_point) {
    float dist = MAX_DIST;
    int obj_hit_a = -1;
    int obj_hit_b = -1;
    float hit_blend = -1.0;

    for (int i = 0; i < scene_data.num_scene_objects * NUM_MATRICES_PER_OBJ; i += 2) {
        mat4 transform = scene_data.data[i];
        mat4 data = scene_data.data[i + 1];
        vec4 mesh_data = data[1];
        int mesh_type = int(data[0].x);
        int sdf_mode = int(data[0].y);
        float blending_factor = data[0].z;

        // since sample_point is in world space, we need to convert it back to local object space using the inv. global transform
        vec3 local_pt = transform_point(sample_point, transform);

        float own_dist = MAX_DIST;
        if (mesh_type == MESH_TYPE_SPHERE) {
            // sphere data: x = radius
            own_dist = sdSphere(local_pt, mesh_data.x);
        } else if (mesh_type == MESH_TYPE_CUBE) {
            // cube data: xyz = size.xyz
            own_dist = sdBox(local_pt, mesh_data.xyz);
        } else if (mesh_type == MESH_TYPE_CYLINDER) {
            // cylinder data: xyz = (top radius, bottom radius, height)
            own_dist = sdCappedCone(local_pt, mesh_data.z, mesh_data.y, mesh_data.x);
        } else if (mesh_type == MESH_TYPE_TORUS) {
            // Godot torus data: xy = (outer radius, inner radius)
            float outer_radius = mesh_data.x;
            float inner_radius = mesh_data.y;
            // SDF torus function takes a radius (major radius) and a width of the torus ring (minor radius)
            float major_radius = mix(outer_radius, inner_radius, 0.5);
            float minor_radius = abs(inner_radius - outer_radius) * 0.5;
            own_dist = sdTorus(local_pt, vec2(major_radius, minor_radius));
        }

        float dist_before = dist;
        float calc_blend = -1.0; // the blend factor which is calculated inside the special smin function
        if (sdf_mode == SDF_MODE_UNION) {
            vec2 res = sdf_union2(dist, own_dist, params.GlobalBlending * blending_factor);
            //dist = min(dist, own_dist);
            dist = res.x;
            calc_blend = res.y;
        } else if (sdf_mode == SDF_MODE_DIFFERENCE) {
            dist = sdf_difference(dist, own_dist, params.GlobalBlending * blending_factor);
        } else if (sdf_mode == SDF_MODE_INTERSECT) {
            dist = sdf_intersect(dist, own_dist, params.GlobalBlending * blending_factor);
        }

        if (dist < dist_before) {
            obj_hit_b = obj_hit_a;
            obj_hit_a = i;
            hit_blend = calc_blend;
        }
    }

    return HitInfo(
        dist,
        obj_hit_a,
        obj_hit_b,
        hit_blend
    );
}

// See: https://learnopengl.com/Getting-Started/Coordinate-Systems
vec3 ray_direction(vec2 screen_uv, mat4 inv_proj, mat4 inv_view) {
    // Convert screen uv into clip space
    // Effectively, calc a pos on the far plane corresponding to the screen uv
    vec4 clip = vec4(screen_uv * 2.0 - 1.0, 1.0, 1.0);
    // Use the inverse proj. matrix to go from clip space back into view space (camera view)
    vec4 view = inv_proj * clip;
    view /= view.w;
    // Use inverse view matrix to go from view space back to world space
    vec4 world = inv_view * vec4(view.xyz, 0.0);
    return normalize(world.xyz);
}

// Tetrahedron technique from
// https://iquilezles.org/articles/normalsSDF/
vec3 calcGradient(vec3 p) {
    const float h = EPSILON;
    const vec2 k = vec2(1, -1);
    return (k.xyy * sceneSDF(p + k.xyy * h).depth +
        k.yyx * sceneSDF(p + k.yyx * h).depth +
        k.yxy * sceneSDF(p + k.yxy * h).depth +
        k.xxx * sceneSDF(p + k.xxx * h).depth);
}

vec3 calcNormal(vec3 p) {
    return normalize(calcGradient(p));
}

// Returns vec4: x = depth, y = last object hit, z = 2nd last object hit, w = blend between hit objects
HitInfo raymarch(vec3 eye, vec3 marchingDirection) {
    HitInfo result = HitInfo(MIN_DIST, 0, 0, 0.0);
    for (int i = 0; i < MAX_MARCHING_STEPS; i++) {
        vec3 sampling_position = eye + result.depth * marchingDirection;
        HitInfo temp_res = sceneSDF(sampling_position);
        result.depth += temp_res.depth;
        if (result.depth >= MAX_DIST || abs(temp_res.depth) < EPSILON) {
            float final_depth = result.depth;
            result = temp_res;
            result.depth = final_depth;
            break;
        }
    }
    return result;
}

// requires HitInfo, transform_*, sceneSDF, but also calcGradient/-Normal
#include "implicit_uvs.glsl"

// For each pixel we need:
// - eye pos = camera position in world
// - dir = ray direction from camera pos through that pixel in the world
void main() {
    ivec2 pos = ivec2(gl_GlobalInvocationID.xy);
    vec2 resolution = params.ViewportSize;
    vec2 screen_uv = vec2(pos) / resolution;

    vec3 eye_pos = params.CamPosWorld;
    vec3 dir = ray_direction(screen_uv, camera_data.inv_projection_matrix, camera_data.view_matrix);
    HitInfo raymarch_res = raymarch(eye_pos, dir);

    vec3 color = vec3(0.0);
    float alpha = 1.0;
    if (raymarch_res.depth < MAX_DIST) {
        // The closest point on the surface to the eyepoint along the view ray
        vec3 p = eye_pos + raymarch_res.depth * dir;
        vec3 n = calcNormal(p);

        if (params.PrecalcStage != 0) {
            precalculate_implicituvs();
        } else {
            LogMap closest_logmap = compute_blended_uvs(p);
            vec2 blend_uv = closest_logmap.uv;
            color = texture(color_tex, blend_uv).rgb;
            // color = vec3(blend_uv, 0.0);
            #if 1 // Use this to debug reasons for compute_logmap/ geodesic walk fail
            if (closest_logmap.return_code != ERR_LOGMAP_OK) {
                switch (closest_logmap.return_code) {
                    case ERR_LOGMAP_MAX_DIST:
                    color = vec3(1.0, 0.0, 0.0);
                    break;
                    case ERR_LOGMAP_SHARP_FEATURE:
                    color = vec3(0.0, 1.0, 0.0);
                    break;
                    case ERR_LOGMAP_MIN_DIST:
                    color = vec3(0.0, 0.0, 1.0);
                    break;
                }
            }
            #endif
        }

        #define SHOW_SEEDS
        #ifdef SHOW_SEEDS
        Seed seeds[NUM_SEEDS_PER_OBJ] = get_seeds(raymarch_res.last_obj_hit / NUM_MATRICES_PER_OBJ);
        for (int i = 0; i < NUM_SEEDS_PER_OBJ; i++) {
            if (!seeds[i].enabled) {
                continue;
            }
            int seed_idx = raymarch_res.last_obj_hit / NUM_MATRICES_PER_OBJ + i;
            Neighbors neighs = get_neighbors(seed_idx);
            float dist = distance(p, seeds[i].position);
            if (dist < 0.03) {
                color = vec3(1.0, 0.0, 0.0);
            }
            #endif // SHOW_SEEDS

            alpha = 1.0;
        }
    } else {
        // Didn't hit anything
        alpha = 0.0;
    }

    // Only write color if we arent precalculating
    if (params.PrecalcStage == 0) {
        imageStore(write_image, pos, vec4(color, alpha));
    }
}

//void light() {
//// Called for every pixel for every light affecting the CanvasItem.
//// Uncomment to replace the default light processing function with this one.
//}
