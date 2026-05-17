function t_profile = define_time_ics(t, t0_gauss, beta_chirp, omega_fund, omega_ref, t_center)
% Built-in temporal launch envelope used by the solver.
% User edit guide:
% - Change the launch-time knobs in cerupp.m first.
% - This helper hardcodes the default Gaussian-in-time envelope law.
% - If you need a different temporal shape, edit or replace this helper for
%   the default temporal law; build_spatiotemporal_ics.m by default
%   consumes the t_profile constructed here unchanged.
% - The profile built by this function is by default applied to both beams
%   when beam 2 is enabled.
% - If you want a fully custom spatiotemporal launch law, or different
%   temporal profiles for both beams, you can bypass define_time_ics.m and
%   hardcode build_spatiotemporal_ics.m.
% - MATLAB FFT detuning Omega contributes exp(+1i*Omega*t) to the stored
%   envelope, so the physical optical-frequency grid is omega_ref - Omega.
% - omega_ref sets the numerical FFT-grid origin used by the solver.
% - omega_fund is the physics expansion point used in the model equations.
%
% Spectral recentering and physical-carrier convention:
% - The model equations and pulse-frame subtraction are written about omega_fund.
% - omega_ref is not the physical optical carrier; it only chooses the
%   numerical FFT-grid origin.
% - The detuning Delta_omega = (omega_fund - omega_ref) shifts the returned
%   solver envelope onto that grid:
%     A_S(t) = A0(t) .* exp(-1i*Delta_omega*t),
%     A0(t) = A_S(t) .* exp(+1i*Delta_omega*t).
% - For a nonzero t_center, the default Gaussian launch applies a full-field
%   delay convention:
%     A_S(t) = A_base(t-t_center) ...
%              .* exp(+1i*omega_fund*t_center) ...
%              .* exp(-1i*(omega_fund-omega_ref)*t).
%   This preserves the physical carrier phase at the shifted pulse peak.
% - The sign is the FFT-grid recentering implied by MATLAB's forward
%   exp(-1i*Omega*t) convention, not a physical carrier change.
% - Stored A_S therefore lives on the omega_ref FFT grid for solver numerics.
% - To reconstruct the physical analytic field, first recover the same
%   omega_fund-rotating intensity-scaled envelope A0 used in cerupp.m:
%     A0(t) = A_S(t) .* exp(+1i*(omega_fund-omega_ref)*t).
% - Then use the physical omega_fund carrier:
%     E^(+)(t) = A0(t)/sqrt(ep0*c*n_sell(omega_fund)/2) .* exp(-1i*omega_fund*t).
%   This last line is the launch-plane shorthand at z=0, where the solver
%   pulse-frame t grid and t_lab coincide. Away from the launch plane, use
%   the full reconstruction in cerupp.m with t_lab = t + z/v_g, or the
%   stored accumulated scalar group delay for z-dependent reference media.

%
% Inputs:
% t           : solver time grid [s]
% t0_gauss    : Gaussian width parameter sigma_t in A(t)=exp(-t^2/(2*sigma_t^2)) [s]
%               (field-envelope variance parameter; intensity RMS is sigma_t/sqrt(2))
% FWHM_ampl = 2*sqrt(2 ln 2) * sigma_t ; FWHM_int = 2*sqrt(ln 2) * sigma_t
% beta_chirp : quadratic chirp parameter [s^2]
% omega_fund  : physical carrier / model-expansion angular frequency
%               before recentering onto omega_ref [rad/s]
% omega_ref   : reference angular frequency defining the FFT-grid origin [rad/s]
% t_center    : temporal center of the launched Gaussian envelope on the
%               solver t grid [s]. Nonzero t_center applies the full-field
%               delay convention above, preserving the carrier phase at the
%               shifted pulse peak.
% Chirp-sign note: beta_chirp is applied to the omega_fund-rotating
% launch envelope A0 before recentering. In A0 coordinates, the
% sigma_c^2 = t0_gauss^2 - i*beta_chirp convention corresponds to
% spectral phase exp(+1i*beta_chirp*Omega0^2/2) under the forward FFT
% kernel exp(-1i*Omega0*t). After A_S=A0*exp(-1i*(omega_fund-omega_ref)*t),
% the same chirped pulse appears shifted on the omega_ref solver grid.

%
% Output:
% t_profile   : complex envelope A_S(t), returned with the same shape as t
%
% Notes:
% Normalization: for the chirped Gaussian model used here
% (sigma_c^2 = t0_gauss^2 - i*beta_chirp applied to A0 before recentering),
% norm_fac = t0_gauss/sqrt(|sigma_c^2|) preserves integral |A_S(t)|^2 dt for the analytic form.
% The realized IC peak power is reported after A_xy is built, with no later global spatial renormalization.
% In this default energy-normalized mode, driver knobs such as p_input and
% i_laser_peak therefore still refer to the transform-limited peak scale,
% not the reduced peak of the broadened chirped pulse.
%==========================================================================

if ~(isnumeric(t) && isreal(t) && isvector(t) && ~isempty(t))
    error('define_time_ics:InvalidTimeGridShape', ...
        't must be a nonempty real numeric vector on a uniform FFT grid.');
end
t_vec = t(:);
if numel(t_vec) < 2
    error('define_time_ics:InvalidTimeGridLength', ...
        't must contain at least two samples on a uniform FFT grid.');
end
if any(~isfinite(t_vec))
    error('define_time_ics:InvalidTimeGridFinite', ...
        't must contain only finite values.');
end
dt_vec = diff(t_vec);
if ~all(dt_vec > 0)
    error('define_time_ics:NonIncreasingTimeGrid', ...
        't must be strictly increasing to define the live FFT grid.');
end
dt_ref = dt_vec(1);
uniform_tol = max(1e-12 * abs(dt_ref), 100 * eps(max(abs([t_vec; dt_ref]))));
max_dt_dev = max(abs(dt_vec - dt_ref));

% The solver builds one FFT frequency grid from one scalar dt, so t must
% stay uniform if omega_window/freq_offset are to represent the same grid.
if max_dt_dev > uniform_tol
    error('define_time_ics:NonuniformTimeGrid', ...
        't must be uniformly spaced; max |diff(t)-dt0| = %.3e exceeds tol %.3e.', ...
        max_dt_dev, uniform_tol);
end
if ~(isscalar(t_center) && isnumeric(t_center) && isreal(t_center) && isfinite(t_center))
    error('define_time_ics:InvalidTemporalCenter', ...
        't_center must be a finite real scalar; got %s.', mat2str(t_center));
end
if ~(isscalar(beta_chirp) && isnumeric(beta_chirp) && isreal(beta_chirp) && isfinite(beta_chirp))
    error('define_time_ics:InvalidBetaChirp', ...
        'beta_chirp must be a finite real scalar; got %s.', mat2str(beta_chirp));
end
if ~(isscalar(omega_fund) && isnumeric(omega_fund) && isreal(omega_fund) && ...
        isfinite(omega_fund) && (omega_fund > 0))
    error('define_time_ics:InvalidOmegaFund', ...
        'omega_fund must be a finite real scalar > 0; got %s.', mat2str(omega_fund));
end
if ~(isscalar(omega_ref) && isnumeric(omega_ref) && isreal(omega_ref) && ...
        isfinite(omega_ref) && (omega_ref > 0))
    error('define_time_ics:InvalidOmegaRef', ...
        'omega_ref must be a finite real scalar > 0; got %s.', mat2str(omega_ref));
end

% Detuning between the physics expansion point and the FFT-grid origin.
domega_shift = omega_fund - omega_ref;
t_shift = t - cast(double(t_center), 'like', t);
imag_unit = cast(1i, 'like', real(t(1)));
t_center_like = cast(double(t_center), 'like', real(t(1)));

% Preserve the carrier phase at the shifted pulse peak while mapping A0 onto
% the omega_ref solver grid.
peak_cep_phase = exp(imag_unit * omega_fund * t_center_like);
recenter_phase = exp(-imag_unit * domega_shift .* t);

if beta_chirp ~= 0
    % Chirped Gaussian path: use the complex variance and
    % energy-preserving normalization.
    sigma2_c = t0_gauss.^2 - cast(1i, 'like', real(t(1))) * beta_chirp;

    % Chirped envelope.
    envelope = exp( -t_shift.^2 ./ (2*sigma2_c) );

    % Preserve integral |A|^2 dt as the chirped pulse broadens.
    norm_fac = t0_gauss ./ sqrt(abs(sigma2_c));
    t_profile = norm_fac .* envelope .* peak_cep_phase .* recenter_phase;
else
    % Transform-limited Gaussian path.
    envelope  = exp( -t_shift.^2 ./ (2*t0_gauss.^2) );
    t_profile = envelope .* peak_cep_phase .* recenter_phase;
end
end
