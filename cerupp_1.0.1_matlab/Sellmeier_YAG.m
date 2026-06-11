function n = Sellmeier_YAG(lambda_m)
% SELLMEIER_YAG  Refractive index of YAG using Zelmon et al. (1998).
%
% PURPOSE
%   Return n(lambda) for YAG. Input lambda_m is provided in meters.
%   Keep this as a pure dispersion law; medium selection belongs in the
%   caller/driver and spatial dependence of n is set in Rod_on_Air.m.
%
% MODEL
%   D. E. Zelmon, D. L. Small, and R. Page, "Refractive-index
%   measurements of undoped yttrium aluminum garnet from 0.4 to 5.0 um,"
%   Appl. Opt. 37, 4933-4935 (1998), DOI: 10.1364/AO.37.004933.
%   n^2 - 1 = (2.28200*lambda_um^2)/(lambda_um^2 - 0.01185)
%          + (3.27644*lambda_um^2)/(lambda_um^2 - 282.734)
%   where lambda_um is wavelength in micrometers (um). Nominal validity: ~0.4-5.0 um.
%
% INPUTS
%   lambda_m   : wavelength(s) in meters (scalar or array).
%
% OUTPUTS
%   n          : refractive index of YAG (same size as lambda_m).
%
% NOTES
%   - Fully vectorized over lambda_m.
%   - The caller is expected to do the main wavelength-range validation once
%     upstream.
%   - Any remaining out-of-range entries are clamped internally to the
%     nominal Zelmon fit interval [0.4, 5.0] um before evaluation.
%     Upstream checks only decide whether the run warns or stops elsewhere.

% Convert meters -> micrometers and build lambda^2 in um^2.
lambda_um = lambda_m / 1e-6;
lambda_um_eval = min(max(lambda_um, 0.4), 5.0);
lambda2 = lambda_um_eval.^2;

% Zelmon Sellmeier coefficients (lambda in um).
b1 = 2.28200; C1 = 0.01185;
b2 = 3.27644; C2 = 282.734;

% Evaluate n^2 directly; caller prevalidates wavelength range/physicality.
n2 = 1 ...
    + (b1 .* lambda2) ./ (lambda2 - C1) ...
    + (b2 .* lambda2) ./ (lambda2 - C2);
n = sqrt(n2);
end
