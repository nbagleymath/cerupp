# CerUPP

CerUPP is a spectrally resolved Forward Envelope Equation solver for
ultrashort-pulse propagation in ceramic, crystal, and other media. 

Please cite the CerUPP manual when using this code:

N. Bagley, "CerUPP: Spectrally resolved ultrashort-pulse envelope propagation
with applications to ceramic and crystal media," available at on researchgate at: [https://doi.org/10.13140/RG.2.2.26038.87363](https://doi.org/10.13140/RG.2.2.22683.43044)

This manual provides details on theory, usage, and examples and should be the main point of reference for developers and users.

The MATLAB release is in `cerupp_1.0.1_matlab/`

The main MATLAB driver is `cerupp.m`. The physics-facing root files include the
propagation stepper, medium models, Sellmeier formulas, mask construction,
launch construction, Keldysh setup/evaluation, nonlinear absorption and plasma
propagation, and rod-on-air geometry.

The `utils/` directories contain setup, validation, checkpoint, diagnostic,
output, plotting, restart, warning, and reporting helpers. The `dev_tools/`
directories contain restart-inspection helpers.

The code is released under the MIT License.
