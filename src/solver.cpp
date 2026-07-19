#include "myextension.h"
#include <Eigen/Core>
#include <Eigen/Eigenvalues>
#include <Eigen/Sparse>
#include <Eigen/SparseCholesky>
#include <godot_cpp/core/class_db.hpp>
#include <unordered_set>

using namespace godot;
using Vec2 = Eigen::Vector2d;
using Mat2 = Eigen::Matrix2d;
using Mat3 = Eigen::Matrix3d;
using Vec3 = Eigen::Vector3d;
using Triplet = Eigen::Triplet<double>;
using SparseMatrix = Eigen::SparseMatrix<double>;

void MyExtension::_bind_methods() {
  ClassDB::bind_method(D_METHOD("optimize_implicituvs", "num_nodes", "offsets",
                                "neighbors", "weights", "matrices",
                                "fixed_frame"),
                       &MyExtension::optimize_implicituvs);
}

MyExtension::MyExtension() {
  // Initialize any variables here.
  time_passed = 0.0;
}

MyExtension::~MyExtension() {
  // Add your cleanup here.
}

// E({ti​}) =  ∑_((i,j) ∈ E) (​∥Aij ti−tj​∥²)/(​wij²).
//
// For one edge: E_{ij} =​ ∥A ti - tj​∥²
// ∥x∥²=x^T x           ==>  ∥Ati​−tj​∥² = (Ati-tj)^T(Ati-tj)
// (X-Y)^T = X^T - Y^t ==> (Ati-tj)^T = (Ati)^T - tj^T
//                         (Ati)^T = ti^T A^T
// So: (ti^T A^T - tj^T)(Ati-tj)
// Multiply and shorten:
// ti^T A^T Ati - 2ti^T A^T tj + tj^T tj
// Because A is a rotation (A^T A = I):
// E_{ij} =​ ti^T ti - 2ti^T A^T tj + tj^T tj

// To get to the blocks we need this quadratic form:
//     x^T H x    to be our energy from above
// x = (ti, tj) so a 6D Vector
// So now we need to find a matrix H which fulfills:
// x^T H x = ti^T ti - 2ti^T A^T tj + tj^T tj
// Lets take a general block matrix, where each entry is a 3x3 block:
// H = [ B11, B12
//       B21, B22 ]
// Multiplying it (x^T H x) gives:
// ti^T B11 ti + ti^T B12 tj + tj^T B21 ti + tj^T B22 tj
// So now this needs to be equal to our energy. Going term-by-term
// gives us 4 Blocks:
// - ti^T B11 ti = ti^T ti  if B11 = I
// - tj^T B12 tj = tj^T tj  if B22 = I
// - ti^T B12 tj + tj^T B21 ti = -2 ti^T A^T tj if:
//       B12 = -A^T   and   B21 = A^T
// So now we know:
// H = [ I, -A^T
//       A^T, I ]
void add_edge(std::unordered_map<int, int> &node_to_unknown,
              std::vector<Triplet> &T, Eigen::VectorXd &b, int i, int j,
              const Mat3 &A, double w, const Eigen::Vector3d &fixed_frame) {
  int ii = -1;
  int jj = -1;
  auto it = node_to_unknown.find(i);
  if (it != node_to_unknown.end()) {
    ii = 3 * it->second;
  }
  it = node_to_unknown.find(j);
  if (it != node_to_unknown.end()) {
    jj = 3 * it->second;
  }

  auto add = [&](int r, int c, const Mat3 &B) {
    if (r < 0 || c < 0)
      return;
    for (int a = 0; a < 3; ++a)
      for (int d = 0; d < 3; ++d)
        T.emplace_back(r + a, c + d, B(a, d));
  };

  double dm = 1.0 / (w * w);

  // both nodes unknown
  if (ii >= 0 && jj >= 0) {
    add(ii, ii, dm * Mat3::Identity());
    add(ii, jj, -dm * A.transpose());
    add(jj, ii, -dm * A);
    add(jj, jj, dm * Mat3::Identity());
    return;
  }

  // i known
  if (ii < 0 && jj >= 0) {
    add(jj, jj, dm * Mat3::Identity());
    b.segment<3>(jj) += dm * (A * fixed_frame);
    return;
  }

  // j known
  if (ii >= 0 && jj < 0) {
    add(ii, ii, dm * Mat3::Identity());
    b.segment<3>(ii) += dm * (A.transpose() * fixed_frame);
    return;
  }
}

Eigen::VectorXd solve_frames(std::unordered_map<int, int> &node_to_unknown,
                             TypedArray<int> offsets, TypedArray<int> neighbors,
                             TypedArray<float> weights,
                             TypedArray<Transform3D> matrices,
                             Vector3 fixed_frame) {

  int unknowns = node_to_unknown.size();
  std::vector<Triplet> triplets;
  triplets.reserve(unknowns * 36); // 4 blocks * 9 entries
  // We use a block matrix with 3x3 blocks
  Eigen::SparseMatrix<double> H(3 * unknowns, 3 * unknowns);
  Eigen::VectorXd b = Eigen::VectorXd::Zero(3 * unknowns);
  Eigen::VectorXd fixed_eigen =
      Vec3{fixed_frame.x, fixed_frame.y, fixed_frame.z};

  for (int i = 0; i < offsets.size() / 2; i++) {
    int range_start = offsets[i * 2];
    int range_end = offsets[i * 2 + 1];
    for (int e = range_start; e < range_end; e++) {
      int j = neighbors[e];
      double w = weights[e];
      // print_line("edge ", i, " -> ", j, "   n=", offsets.size() / 2,
      //            "   w=", w);

      Transform3D trans = matrices[e];
      const Mat3 A{
          {trans.basis.rows[0].x, trans.basis.rows[0].y, trans.basis.rows[0].z},
          {trans.basis.rows[1].x, trans.basis.rows[1].y, trans.basis.rows[1].z},
          {trans.basis.rows[2].x, trans.basis.rows[2].y,
           trans.basis.rows[2].z}};

      add_edge(node_to_unknown, triplets, b, i, j, A, w, fixed_eigen);
    }
  }

  for (const auto &t : triplets) {
    if (t.row() < 0 || t.row() >= H.rows() || t.col() < 0 ||
        t.col() >= H.cols()) {

      print_line("Bad triplet: row=", t.row(), "  col=", t.col(),
                 "  value=", t.value());
    }
  }
  H.setFromTriplets(triplets.begin(), triplets.end());

  Eigen::SimplicialLDLT<Eigen::SparseMatrix<double>> solver;
  solver.compute(H);

  // print_line("H size: " + String::num(H.rows()) + " x " +
  //            String::num(H.cols()));
  // print_line("unknowns: " + String::num(unknowns));
  // print_line("triplets: " + String::num(triplets.size()));
  // print_line("nonzeros: " + String::num(H.nonZeros()));
  // Eigen::MatrixXd dense = Eigen::MatrixXd(H);

  // for (int r = 0; r < dense.rows(); r++) {
  //   String line = "";
  //   for (int c = 0; c < dense.cols(); c++) {
  //     line += String::num(dense(r, c)) + " ";
  //   }
  //   print_line(line);
  // }

  if (solver.info() != Eigen::Success) {
    print_line(String("Computing frames failed: ") +
               String::num(int(solver.info())));
    Eigen::SelfAdjointEigenSolver<Eigen::MatrixXd> es{Eigen::MatrixXd(H)};
    print_line("min eigenvalue: " + String::num(es.eigenvalues()[0]));
  }

  Eigen::VectorXd x = solver.solve(b);

  if (solver.info() != Eigen::Success) {
    print_line(String("Solving frames failed: ") +
               String::num(int(solver.info())));
  }
  return x;
}

void add_offset_edge(std::unordered_map<int, int> &node_to_unknown,
                     std::vector<Triplet> &T, Eigen::VectorXd &b, int i, int j,
                     const Vec2 &logmap, double w) {
  int ii = -1;
  int jj = -1;
  auto it = node_to_unknown.find(i);
  if (it != node_to_unknown.end()) {
    ii = 2 * it->second;
  }
  it = node_to_unknown.find(j);
  if (it != node_to_unknown.end()) {
    jj = 2 * it->second;
  }

  auto add = [&](int r, int c, const Mat2 &M) {
    if (r < 0 || c < 0)
      return;

    for (int a = 0; a < 2; ++a)
      for (int b2 = 0; b2 < 2; ++b2)
        T.emplace_back(r + a, c + b2, M(a, b2));
  };

  double dm = 1.0 / (w * w);
  Mat2 I = dm * Mat2::Identity();

  add(ii, ii, I);
  add(ii, jj, -I);
  add(jj, ii, -I);
  add(jj, jj, I);

  // RHS
  if (ii >= 0)
    b.segment<2>(ii) += dm * logmap;

  if (jj >= 0)
    b.segment<2>(jj) -= dm * logmap;
}

Eigen::VectorXd solve_offsets(std::unordered_map<int, int> &node_to_unknown,
                              TypedArray<int> offsets,
                              TypedArray<int> neighbors,
                              TypedArray<float> weights,
                              TypedArray<Vector2> uvs) {

  int unknowns = node_to_unknown.size();
  Eigen::VectorXd b = Eigen::VectorXd::Zero(2 * unknowns);
  std::vector<Triplet> triplets;

  for (int i = 0; i < offsets.size() / 2; i++) {
    int range_start = offsets[i * 2];
    int range_end = offsets[i * 2 + 1];
    for (int e = range_start; e < range_end; e++) {
      int j = neighbors[e];
      double w = weights[e];
      Vector2 uv = uvs[e];
      Vec2 logmap{uv.x, uv.y};

      add_offset_edge(node_to_unknown, triplets, b, i, j, logmap, w);
    }
  }

  Eigen::SparseMatrix<double> H(2 * unknowns, 2 * unknowns);
  // print_line("Checking triplets 2...");
  // for (const auto &t : triplets) {
  //   if (t.row() < 0 || t.row() >= H.rows() || t.col() < 0 ||
  //       t.col() >= H.cols()) {

  //     print_line("Bad triplet: row=", t.row(), "  col=", t.col(),
  //                "  value=", t.value());
  //   }
  // }
  H.setFromTriplets(triplets.begin(), triplets.end());

  Eigen::SimplicialLDLT<Eigen::SparseMatrix<double>> solver;
  solver.compute(H);

  if (solver.info() != Eigen::Success) {
    print_line(String("Computing offsets failed: ") +
               String::num(int(solver.info())));
    Eigen::SelfAdjointEigenSolver<Eigen::MatrixXd> es{Eigen::MatrixXd(H)};
    print_line("min eigenvalue: " + String::num(es.eigenvalues()[0]));
  }

  Eigen::VectorXd x = solver.solve(b);

  if (solver.info() != Eigen::Success) {
    print_line(String("Solving offsets failed: ") +
               String::num(int(solver.info())));
  }
  return x;
}

TypedArray<Transform3D> MyExtension::optimize_implicituvs(
    int num_nodes, TypedArray<int> offsets, TypedArray<int> neighbors,
    TypedArray<float> weights, TypedArray<Transform3D> matrices,
    TypedArray<Vector2> uvs, Vector3 fixed_frame) {
  // print_line("A");
  // build a set of nodes which are in the graph
  // Because in theory we can have seeds like
  // [0, 1, 2, 3, 4] where [0, 1, 2] are the seeds from
  // one object and 2 is inactive, so in the graph
  // it goes [0, 1, 3, 4, 6, 7, ...] (skipping inactive)
  std::unordered_set<int> existing_nodes;
  for (int i = 0; i < offsets.size() / 2; i++) {
    int start = offsets[i * 2];
    int end = offsets[i * 2 + 1];

    if (start != end) {
      existing_nodes.insert(i);
    }

    for (int e = start; e < end; e++) {
      existing_nodes.insert(neighbors[e]);
    }
  }

  // print_line("B");

  std::unordered_map<int, int> node_to_unknown;
  int counter = 0;
  for (int node : existing_nodes) {
    if (node != 0) {
      node_to_unknown[node] = counter++;
    }
  }

  // print_line("C");
  Eigen::VectorXd optimal_frames = solve_frames(
      node_to_unknown, offsets, neighbors, weights, matrices, fixed_frame);

  // print_line("D");
  Eigen::VectorXd optimal_offsets =
      solve_offsets(node_to_unknown, offsets, neighbors, weights, uvs);

  // for (int i = 0; i < optimal_offsets.size() / 2; i += 2) {
  //   Vec2 u = optimal_offsets.segment<2>(i);
  //   print_line(i, "    ", u.x(), " ", u.y());
  // }

  // print_line("E");
  // assemble the result vector
  Vector3 z = Vector3(0.0, 0.0, 0.0);

  TypedArray<Transform3D> result;
  result.resize(offsets.size() / 2);
  result.fill(Transform3D(z, z, z, z));
  result[0] = Transform3D(fixed_frame, z, z, z);

  for (auto &[node_id, unknown] : node_to_unknown) {
    Vec3 t = optimal_frames.segment<3>(3 * unknown);
    Vector3 t_godot = Vector3(t.x(), t.y(), t.z());
    Vec2 u = optimal_offsets.segment<2>(2 * unknown);
    result[node_id] = Transform3D(t_godot, Vector3(u.x(), u.y(), 0.0), z, z);
  }

  return result;
}
