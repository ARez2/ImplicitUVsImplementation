# ImplicitUVsImplementation
A GLSL implementation of the paper "Implicit UVs: Real-time semi-global parameterization of implicit surfaces".

Note: I am not one of the authors. All credit goes to them.

Link to paper: https://doi.org/10.1111/cgf.70056

This is not a valid GLSL shader by itself.

I have also added the C++ code where I use the [Eigen](https://libeigen.gitlab.io/) library for solving the linear SPD system. I am using this code as a GDExtension inside of Godot.