# CerUPP

CerUPP is a spectrally resolved Forward Envelope Equation solver for
ultrashort-pulse propagation in ceramic, crystal, and other media. 

Please cite the CerUPP arXiv manual when using this code:

N. Bagley, "CerUPP: Spectrally resolved ultrashort-pulse envelope propagation
with applications to ceramic and crystal media," available on arXiv or researchgate

This manual provides details on theory, usage, and examples and should be the main point of reference for developers and users.

The MATLAB release is in `cerupp_1.0.1_matlab/`. The Julia and C++
versions are in `cerupp_0.9.0_julia/` and `cerupp_0.9.0_cpp/`.

The main MATLAB driver is `cerupp.m`. The physics-facing root files include the
propagation stepper, medium models, Sellmeier formulas, mask construction,
launch construction, Keldysh setup/evaluation, nonlinear absorption and plasma
propagation, and rod-on-air geometry.

The `utils/` directories contain setup, validation, checkpoint, diagnostic,
output, plotting, restart, warning, and reporting helpers. The `dev_tools/`
directories contain restart-inspection helpers.

The code is released under the MIT License.
