
const int NUM_SEEDS_PER_OBJ = 3;
const int TOTAL_NR_SEEDS = MAX_NUM_OBJECTS * NUM_SEEDS_PER_OBJ;
const int NUM_MERGING_EDGES = TOTAL_NR_SEEDS * TOTAL_NR_SEEDS;
const int MAX_NUM_MERGE_NEIGHBORS = 16;

layout(set = 1, binding = 0, std430) restrict buffer SeedBuffer {
    mat4 Seeds[TOTAL_NR_SEEDS];
} seed_buffer;
// Merging Graph (CSR-Layout):
layout(set = 1, binding = 1, std430) restrict buffer MergingGraph {
    // tells for each seed which indices range to use to access the neighbors and weights.
    // for each seed, it stores 2 numbers: [start, end)
    int MergingGraphOffsets[TOTAL_NR_SEEDS * 2];
    // stores which other seeds to merge a seed with
    int MergingGraphNeighbors[TOTAL_NR_SEEDS * MAX_NUM_MERGE_NEIGHBORS];
    // stores with what weight to merge that neighbor
    float MergingGraphWeights[TOTAL_NR_SEEDS * MAX_NUM_MERGE_NEIGHBORS];
} merging_graph;

layout(set = 1, binding = 2, std430) restrict buffer PrecalcBuffer {
    float NewBlendingWidth;
    mat3 TransportMatrices[TOTAL_NR_SEEDS * MAX_NUM_MERGE_NEIGHBORS];
    vec2 Logmaps[TOTAL_NR_SEEDS * MAX_NUM_MERGE_NEIGHBORS];
} precalc_buffer;

struct Neighbors {
    int count;
    vec2 neighbor_list[MAX_NUM_MERGE_NEIGHBORS];
};

// Returns an array of vec2, where x = float(neighbor) and y = weight to neighbor
Neighbors get_neighbors(int seed) {
    int range_start = merging_graph.MergingGraphOffsets[seed * 2];
    int range_end = merging_graph.MergingGraphOffsets[seed * 2 + 1];
    int num_neighs = range_end - range_start;

    vec2 neighbor_list[MAX_NUM_MERGE_NEIGHBORS];
    if (num_neighs == 0) {
        return Neighbors(0, neighbor_list);
    }

    int n = 0;
    for (int i = range_start; i < range_end; i++) {
        int neighbor = merging_graph.MergingGraphNeighbors[i];
        float weight = merging_graph.MergingGraphWeights[i];
        neighbor_list[n] = vec2(float(neighbor), weight);
        n++;
    }
    return Neighbors(num_neighs, neighbor_list);
}

struct Seed {
    vec3 position;
    vec3 e1;
    vec3 e2;
    vec2 offset;
    // Some seeds might not be in active/ valid (but we need to return them in an array)
    bool enabled;
};

Seed get_seed(int global_seed_idx) {
    mat4 s = seed_buffer.Seeds[global_seed_idx];
    return Seed(s[0].xyz, s[1].xyz, s[2].xyz, s[3].xy, bool(s[3].z));
}

Seed[NUM_SEEDS_PER_OBJ] get_seeds(int for_obj) {
    Seed own_seeds[NUM_SEEDS_PER_OBJ];
    for (int i = 0; i < NUM_SEEDS_PER_OBJ; i++) {
        own_seeds[i] = get_seed(for_obj * NUM_SEEDS_PER_OBJ + i);
    }
    return own_seeds;
}

// Uses bubble sort to sort seeds by euclidian distance from the pt parameter in ascending order
int[TOTAL_NR_SEEDS] sort_seeds_by_eucl_distance(Seed seeds[TOTAL_NR_SEEDS], vec3 pt) {
    int sorted_indices[TOTAL_NR_SEEDS];
    for (int i = 0; i < TOTAL_NR_SEEDS; i++) {
        sorted_indices[i] = i;
    }

    for (int i = 0; i < TOTAL_NR_SEEDS - 1; i++) {
        bool swapped = false;
        for (int j = 0; j < TOTAL_NR_SEEDS - i - 1; j++) {
            Seed seed1 = seeds[sorted_indices[j]];
            Seed seed2 = seeds[sorted_indices[j + 1]];
            // Because of the way we structure the seeds array, at the end, there will only be inactive seeds
            if (!seed1.enabled || !seed2.enabled) {
                continue;
            }
            float dist1 = distance(pt, seed1.position);
            float dist2 = distance(pt, seed2.position);
            if (dist1 > dist2) {
                int tmp = sorted_indices[j];
                sorted_indices[j] = sorted_indices[j + 1];
                sorted_indices[j + 1] = tmp;

                swapped = true;
            }
        }
        if (!swapped) {
            break;
        }
    }
    return sorted_indices;
}

// sec 3.1.3, eq. 17
float hessian_three_point(vec3 pt, vec3 dir) {
    float h = 0.01;
    float f0 = sceneSDF(pt - h * dir).depth;
    float f1 = 2.0 * sceneSDF(pt).depth;
    float f2 = sceneSDF(pt + h * dir).depth;
    return (f0 - f1 + f2) / pow(h, 2);
}

vec3 project_onto_tangentplane(vec3 dir, vec3 n) {
    return dir - n * dot(dir, n);
}

// Tetrahedron technique from
// https://iquilezles.org/articles/normalsSDF/
// but with division by h
vec3 calc_discrete_gradient(vec3 p) {
    const float h = EPSILON;
    const vec2 k = vec2(1, -1);
    return (k.xyy * sceneSDF(p + k.xyy * h).depth +
        k.yyx * sceneSDF(p + k.yyx * h).depth +
        k.yxy * sceneSDF(p + k.yxy * h).depth +
        k.xxx * sceneSDF(p + k.xxx * h).depth) / h;
}

const int ERR_LOGMAP_OK = 0;
const int ERR_LOGMAP_MAX_DIST = 1;
const int ERR_LOGMAP_SHARP_FEATURE = 2;
const int ERR_LOGMAP_MIN_DIST = 3;
const int ERR_LOGMAP_OTHER = 4;

struct LogMap {
    // see constants above for values
    int return_code;
    vec2 uv;
    float geodesic_dist;
    // matrix, which transforms a vector in the tangent plane of a seed, into a vector on the tangent plane of a point
    mat3 parallel_transport_matrix;
};

// The maximum distance the logmap walk (alg. 1) is allowed to walk
const float MAX_WALK_DIST = 20.0;

// Calculates a matrix, that transforms a vector from one tangent plane (given by n1) to the next (given by n2)
// It does the minimal rotation neccessary
mat3 build_rotation_matrix(vec3 n1, vec3 n2) {
    mat3 mat;
    // this is the axis, that we need to rotate around
    vec3 axis = cross(n1, n2);
    // the angle we want to rotate by
    float c = dot(n1, n2);
    // J = skew-symmetric matrix (also see Rodrigues-Rotation but from 2 normals)
    mat3 J = mat3(
            vec3(0.0, axis.z, -axis.y),
            vec3(-axis.z, 0.0, axis.x),
            vec3(axis.y, -axis.x, 0.0)
        );
    // Rodrigues-Rotation: R = I + sin theta * J + (1 - cos theta) * J^2
    return mat3(1.0) + J + (1.0 / (1.0 + c)) * (J * J);
}

// Algorithm 1 from the paper
// Does a walk on the surface of the surface from query_pt towards the seed.
// Returns a LogMap, where the geodesic distance is FLOAT_INF if there was a failure.
// Check the return code for reason for failure
LogMap compute_logmap(vec3 query_pt, Seed seed, float max_walk_dist) {
    LogMap FAIL = LogMap(ERR_LOGMAP_OTHER, vec2(0.0), FLOAT_INF, mat3(1.0));
    // The distance to the seed which the walk MUST reach, else its a fail (r_min in the paper)
    const float MIN_WALK_DIST = 1.0;
    const int MAX_STEPS = 16 * 1;
    const float EPS_1 = 0.001;
    const float EPS_SHARP = 0.2;

    if (distance(query_pt, seed.position) > max_walk_dist) {
        // use this as reason for failure
        FAIL.return_code = ERR_LOGMAP_MAX_DIST;
        return FAIL;
    }

    vec3 cur_pos = query_pt;
    vec3 prev_pos = cur_pos;
    float accum_length = 0.0;
    // Gradient at the current point, carried across iterations (updated at the
    // bottom of the loop) so the field is never evaluated twice at one location.
    vec3 gradient = calc_discrete_gradient(cur_pos);
    float grad_len = length(gradient);
    vec3 n = gradient / grad_len;
    // this is called "R" in the paper. Initialized as identity
    mat3 transport_matrix = mat3(1.0);

    for (int i = 0; i < MAX_STEPS; i++) {
        vec3 dir = seed.position - cur_pos;
        vec3 v = project_onto_tangentplane(dir, n);

        // heuristic fail (sec 3.6.1)
        float len_v = length(v);
        if (len_v < EPS_1) {
            break;
        }
        // normalize v
        v /= len_v;
        // Local quadratic (curvature) coefficient of the geodesic (eq. 16):
        //   alpha = -<v, H_f v> / ||grad f||. grad_len is reused from the previous
        //   step's projection point (next_pos ~ step_tmp_pos), so we skip a second
        //   gradient evaluation at cur_pos.
        float curvature = hessian_three_point(cur_pos, v); // <v, H_f(x_i) v>
        float alpha = -curvature / grad_len;
        float alpha2 = alpha * alpha;

        // Compute adaptive time step (sec 3.6.2, eq. 34).
        // When the surface is flat (H_f = 0 => alpha = 0), we recover tau = s.
        // dir == seed.position - cur_pos, so length(dir) is the distance to the seed.
        float s = length(dir) / float(MAX_STEPS - i);
        float tau;
        if (alpha2 < 1e-12) {
            tau = s;
        } else {
            tau = sqrt(2.0 * (sqrt(1.0 + s * s * alpha2) - 1.0) / alpha2);
        }
        float tau2 = tau * tau;

        // One second-order geodesic step (eq. 16):
        //   gamma_i(tau) = x_i + tau v + (tau^2 / 2) alpha n
        vec3 step_tmp_pos = cur_pos + tau * v + (0.5 * tau2) * alpha * n;

        // project back onto the surface (eq. 18): Pi_f(x) = x - f(x) grad f / ||grad f||^2
        // (no assumption that ||grad f|| == 1).
        vec3 grad_next = calc_discrete_gradient(step_tmp_pos);
        float grad_next_len = length(grad_next);
        vec3 n_next = grad_next / grad_next_len; // unit normal
        vec3 next_pos = step_tmp_pos - sceneSDF(step_tmp_pos).depth * grad_next / (grad_next_len * grad_next_len);

        // sharp feature detection (sec 3.5.2)
        if (dot(n_next, n) < 1.0 - EPS_SHARP) {
            FAIL.return_code = ERR_LOGMAP_SHARP_FEATURE;
            return FAIL;
        }

        // transport_matrix = transport_matrix * build_rotation_matrix(n, n_next);
        transport_matrix = transport_matrix * build_rotation_matrix(n_next, n);

        // Arc length of gamma_i over [0, tau] via Simpson's rule (sec. 3.2).
        // ||gamma'(t)|| = sqrt(1 + t^2 alpha^2); reuse tau^2 * alpha^2.
        float tau2alpha2 = tau2 * alpha2;
        float speed_mid = sqrt(1.0 + 0.25 * tau2alpha2);
        float speed_end = sqrt(1.0 + tau2alpha2);
        accum_length += (tau / 6.0) * (1.0 + 4.0 * speed_mid + speed_end);
        if (accum_length + distance(next_pos, seed.position) > max_walk_dist) {
            FAIL.return_code = ERR_LOGMAP_MAX_DIST;
            return FAIL;
        }

        prev_pos = cur_pos;
        cur_pos = next_pos;
        n = n_next;
        grad_len = grad_next_len; // carry this point's gradient magnitude forward
    }
    float final_dist = distance(cur_pos, seed.position);
    if (final_dist < MIN_WALK_DIST) {
        accum_length += final_dist;

        vec3 seed_normal = normalize(cross(seed.e1, seed.e2));
        vec3 t = normalize(project_onto_tangentplane(prev_pos - seed.position, seed_normal));
        vec2 uv = accum_length * vec2(dot(t, seed.e1), dot(t, seed.e2));
        // mat3 trans = transport_matrix * build_rotation_matrix(n, seed_normal);
        mat3 trans = transport_matrix * build_rotation_matrix(seed_normal, n);
        return LogMap(ERR_LOGMAP_OK, uv, accum_length, trans);
    }
    FAIL.return_code = ERR_LOGMAP_MIN_DIST;
    return FAIL;
}

// the omega from sec. 4.3.1 (just under eq. 40)
float weighting_function(float t) {
    return 3.0 * pow(t, 2.0) - 2.0 * pow(t, 3.0);
}

// sec. 4.3.1, eq. 40
float get_weight(float d_x_pi, float d_x_pj, float d_pj_pi) {
    // sec. 4.3.1 eq. 39
    float d_Vij = (pow(d_x_pi, 2.0) - pow(d_x_pj, 2.0)) / (2.0 * d_pj_pi);
    if (d_Vij < -params.ImplicitUVsBlending) {
        return 1.0;
    } else if (params.ImplicitUVsBlending < d_Vij) {
        return 0.0;
    } else {
        return weighting_function(0.5 - d_Vij / (2.0 * params.ImplicitUVsBlending));
    }
}

// Algorithm 2 from the paper.
// Collects the seeds from all objects, finds the geodesicly clostest seed and
// then uses algorithm 1 (logmap) to march towards that seed
LogMap compute_blended_uvs(vec3 pt) {
    // Collect seeds from all objects in the scene
    Seed all_seeds[TOTAL_NR_SEEDS];
    int current_seed_idx = 0;
    for (int obj_idx = 0; obj_idx < scene_data.num_scene_objects; obj_idx++) {
        Seed obj_seeds[NUM_SEEDS_PER_OBJ] = get_seeds(obj_idx);
        for (int s = 0; s < NUM_SEEDS_PER_OBJ; s++) {
            all_seeds[current_seed_idx] = obj_seeds[s];
            current_seed_idx++;
            if (obj_seeds[s].enabled) {}
        }
    }
    // Perfomance optimization: set all the rest of the objects in the array to not be active so we can skip them
    // when sorting and when calculating the geodesic distance
    //for (int i = current_seed_idx; i < TOTAL_NR_SEEDS; i++) {
    //all_seeds[i].enabled = false;
    //}

    int sorted_indices[TOTAL_NR_SEEDS] = sort_seeds_by_eucl_distance(all_seeds, pt);

    int best_idx = sorted_indices[0];
    // L* in the paper
    LogMap best_logmap = compute_logmap(pt, all_seeds[best_idx], MAX_WALK_DIST);
    // d*M in the paper
    float best_geo_dist = best_logmap.geodesic_dist;

    for (int k = 1; k < TOTAL_NR_SEEDS; k++) {
        int seed_idx = sorted_indices[k];
        // Perfomance optimization: Skip all the inactive seeds at the end
        if (!all_seeds[seed_idx].enabled) {
            continue;
        }

        // a seed cant be geodescially closer if the eucl. distance is greater
        // than the current best geodesic distance (sec. 4.1, eq 35)
        if (distance(pt, all_seeds[seed_idx].position) <= best_geo_dist) {
            LogMap l = compute_logmap(pt, all_seeds[seed_idx], best_geo_dist);
            if (l.geodesic_dist < best_geo_dist) {
                best_idx = seed_idx;
                best_logmap = l;
                best_geo_dist = l.geodesic_dist;
            }
        }
    }

    if (best_idx == -1) {
        best_logmap.return_code = ERR_LOGMAP_MAX_DIST;
        return best_logmap;
    }

    Seed pi = all_seeds[best_idx];

    Neighbors neighbors = get_neighbors(best_idx);
    if (neighbors.count == 0) {
        best_logmap.uv += pi.offset;
        return best_logmap;
    } else {
        // get the 2 logmaps, get weight bei calling get_weights(best_geo_dist, other_logmap.geo_dist, blend_weight)
        vec2 L = vec2(0.0);
        float wi = 1.0;
        float W = 0.0;

        for (int i = 0; i < neighbors.count; i++) {
            vec2 data = neighbors.neighbor_list[i];
            int j = int(data.x);
            Seed pj = get_seed(j);
            // The papers says that we need weight from j to i
            // but that should be the same as from i to j
            float d_ji = data.y;

            // test from sec. 4.3.3
            if (pow(best_geo_dist, 2.0) + 2.0 * params.ImplicitUVsBlending * d_ji >= pow(distance(pt, pj.position), 2.0)) {
                LogMap Lj = compute_logmap(pt, pj, best_geo_dist + 2.0 * params.ImplicitUVsBlending);

                // w_i*j in the paper
                float w_ij = get_weight(best_geo_dist, Lj.geodesic_dist, d_ji);
                // sec. 4.3.2, eq. 41
                wi = min(wi, w_ij);
                // sec. 4.3.2, eq. 42
                float w_ji = 1.0 - w_ij;

                L += w_ji * (Lj.uv + pj.offset);
                W += w_ji;
            }
        }

        // deviation from the paper (downloaded 30.4.26)
        // following a suggestion from one of the authors
        best_logmap.uv = (L + wi * (best_logmap.uv + pi.offset)) / (W + wi);
        return best_logmap;
    }
}

// Gets called from main shader, if params.Precalculate is true.
// Calculates all the distances between seeds, sets them as edge weights
// and uses the parallel transport matrix
void precalculate_implicituvs() {
    // according to 4.3.1 in the paper, the blending width is
    // 1/3 * min distance between seeds over all seeds
    float min_dist = 1234.0;
    for (int seed = 0; seed < TOTAL_NR_SEEDS; seed++) {
        int range_start = merging_graph.MergingGraphOffsets[seed * 2];
        int range_end = merging_graph.MergingGraphOffsets[seed * 2 + 1];

        Seed pi = get_seed(seed);

        if (!pi.enabled) {
            continue;
        }
        for (int n = range_start; n < range_end; n++) {
            int neighbor = merging_graph.MergingGraphNeighbors[n];
            Seed pj = get_seed(neighbor);
            if (!pj.enabled || seed == neighbor) {
                continue;
            }

            // FIXME: why does the walk from the exact seed position go through the middle?
            // might be related to instability of normal or tangentplane projection
            LogMap map_between_seeds = compute_logmap(pi.position + pi.e1 * 0.005, pj, MAX_WALK_DIST);

            if (map_between_seeds.return_code == ERR_LOGMAP_OK) {
                min_dist = min(min_dist, map_between_seeds.geodesic_dist);
                merging_graph.MergingGraphWeights[n] = map_between_seeds.geodesic_dist;
                // R_{i -> j} in the paper (Eq. 45/48). The walk uses seed = pj,
                // query = pi, so compute_logmap returns R_{T_pj M -> T_pi M} = R_{j -> i}.
                // The frame solver expects R_{i -> j}, so transpose (== inverse for a rotation).
                precalc_buffer.TransportMatrices[n] = transpose(map_between_seeds.parallel_transport_matrix);
                precalc_buffer.Logmaps[n] = map_between_seeds.uv;
            } else {
                merging_graph.MergingGraphWeights[n] = -float(map_between_seeds.return_code) * 10.0;
            }
        }
    }

    precalc_buffer.NewBlendingWidth = (1.0 / 3.0) * min_dist;
}

