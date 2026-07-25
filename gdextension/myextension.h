#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/transform3d.hpp>

namespace godot {

class MyExtension : public RefCounted {
  GDCLASS(MyExtension, RefCounted)

private:
  double time_passed;

protected:
  static void _bind_methods();

public:
  MyExtension();
  ~MyExtension();

  TypedArray<Vector3> optimize_frames(TypedArray<int> offsets,
                                      TypedArray<int> neighbors,
                                      TypedArray<float> weights,
                                      TypedArray<Transform3D> matrices,
                                      Vector3 fixed_frame);

  TypedArray<Vector2> optimize_offsets(TypedArray<int> offsets,
                                       TypedArray<int> neighbors,
                                       TypedArray<float> weights,
                                       TypedArray<Vector2> uvs);
};
} // namespace godot