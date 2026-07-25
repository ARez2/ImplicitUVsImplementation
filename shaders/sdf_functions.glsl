float dot2(vec2 x) {
    return dot(x, x);
}

// https://iquilezles.org/articles/smin
// Quadratic Polynomial Smooth-minimum with returned blending factor
vec2 smin2(float a, float b, float k) {
    k *= 4.0;
    float h = max(k - abs(a - b), 0.0) / k;

    #if 0
    float m = h * h * 0.5;
    float s = m * k * (1.0 / 2.0);
    #else
    float s = h * h * k / 4.0;
    float m = h * 0.5;
    #endif
    return (a < b) ? vec2(a - s, m) : vec2(b - s, 1.0 - m);
}
// quadratic polynomial
float smin(float a, float b, float k)
{
    k *= 4.0;
    float h = max(k - abs(a - b), 0.0) / k;
    return min(a, b) - h * h * k * (1.0 / 4.0);
}

float smax(float a, float b, float k)
{
    float h = max(k - abs(a - b), 0.0);
    return max(a, b) + h * h * 0.25 / k;
}

float sdf_intersect(float distA, float distB, float blend) {
    return smax(distA, distB, blend);
}

vec2 sdf_union2(float distA, float distB, float blend) {
    return smin2(distA, distB, blend);
}
float sdf_union(float distA, float distB, float blend) {
    return smin(distA, distB, blend);
}

float sdf_difference(float distA, float distB, float blend) {
    return smax(distA, -distB, blend);
}

float sdSphere(vec3 p, float s) {
    return length(p) - s;
}

float sdBox(vec3 p, vec3 b) {
    vec3 d = abs(p) - b;
    return min(max(d.x, max(d.y, d.z)), 0.0) + length(max(d, 0.0));
}

float sdCappedCone(vec3 p, float h, float r1, float r2) {
    vec2 q = vec2(length(p.xz), p.y);
    vec2 k1 = vec2(r2, h);
    vec2 k2 = vec2(r2 - r1, 2.0 * h);
    vec2 ca = vec2(q.x - min(q.x, (q.y < 0.0) ? r1 : r2), abs(q.y) - h);
    vec2 cb = q - k1 + k2 * clamp(dot(k1 - q, k2) / dot2(k2), 0.0, 1.0);
    float s = (cb.x < 0.0 && ca.y < 0.0) ? -1.0 : 1.0;
    return s * sqrt(min(dot2(ca), dot2(cb)));
}

float sdTorus(vec3 p, vec2 t) {
    vec2 q = vec2(length(p.xz) - t.x, p.y);
    return length(q) - t.y;
}
