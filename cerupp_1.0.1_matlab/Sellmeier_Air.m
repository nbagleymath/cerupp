function n = Sellmeier_Air(lambda_m)
% SELLMEIER_AIR  Refractive index of dry air from the Ciddor dry-air formula.
%
% PURPOSE
%   Return n(lambda) for dry air. Input lambda_m is provided in meters.
%   Keep this as a pure dispersion law; medium selection belongs in the
%   caller/driver and spatial dependence of n is set in Rod_on_Air.m.
%
% MODEL (Ciddor, Appl. Opt. 35, 1566-1573 (1996))
%   n(lambda_m)= 1 + B1/(B2 - lambda_um^-2) + B4/(B3 - lambda_um^-2),
%   where lambda_um = lambda_m / 1e-6.
%   This helper uses the standard dry-air coefficient set
%     0.05792105/(238.0185-sigma^2) + 0.00167917/(57.362-sigma^2)
%   with sigma^2 = lambda_um^-2. No pressure, temperature, or CO2
%   corrections are included here. CerUPP evaluates this dry-air formula over
%   the Ciddor validity interval, 0.23-1.69 um.
%
% INPUTS
%   lambda_m   : wavelength(s) in meters (scalar or array).
%
% OUTPUTS
%   n          : refractive index of air (same size as lambda_m).
%
% NOTES
%   - Fully vectorized over lambda_m.
%   - The caller is expected to do the main wavelength-range validation once
%     upstream.
%   - Any remaining out-of-range entries are clamped internally to the
%     dry-air validity/clamp interval [0.23, 1.69] um before evaluation.
%     Upstream checks only decide whether the run warns or stops elsewhere.

    b1= 0.05792105;
    b2= 238.0185;
    b3= 57.362;
    b4= 0.00167917;
    lambda_um = lambda_m / 1e-6;         % meters -> micrometers (um)
    lambda_um_eval = min(max(lambda_um, 0.23), 1.69);
    sigma2    = 1 ./ (lambda_um_eval.^2);     % lambda_um.^2 has units um^2, so sigma2 is (1/um^2)

    n = 1 ...
      + b1 ./ (b2 - sigma2) ...
      + b4 ./ (b3 - sigma2);

end
