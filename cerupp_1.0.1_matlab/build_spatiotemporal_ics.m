function A_xy= build_spatiotemporal_ics( ...
  x_offset, y_offset, x_offset_beam2, y_offset_beam2, ...
  w0, i_laser_peak, i_laser_peak_beam2, ...
  dkx_offset, dky_offset, dkx_offset_beam2, dky_offset_beam2, ...
  t_profile, noise_amplitude, oam_charge1, oam_charge_beam2, x2_d, y2_d, rng_seed)
%========================================================================== 
% BUILD_SPATIOTEMPORAL_ICS 
%========================================================================== 
% Construct the launched envelope A_xy(x,y,t) from two explicit beam
% definitions, a caller-supplied temporal profile, optional tilts/OAM, and
% optional complex Gaussian noise.
%
% Launch model:
% - Each beam uses the Gaussian field envelope A(x,y) = A0 * exp(-(R/w0)^2),
%   so I(x,y) = |A0|^2 * exp(-2*R^2/w0^2).
% - t_profile is supplied by define_time_ics.m or otherwise by the driver
%   and is broadcast along x and y.
% - dkx/dky add transverse tilt phases about each beam center.
% - Nonzero OAM multiplies the Gaussian envelope by a simple vortex factor
%   (sqrt(2)*r/w0)^|l| * exp(+1i*l*phi), not a full Laguerre-Gaussian mode.
% - By default the caller-supplied temporal profile is applied to both
%   beams when beam 2 is enabled.
% - If you want a fully custom spatiotemporal launch law, or different
%   temporal profiles for both beams, bypass define_time_ics.m and hardcode
%   build_spatiotemporal_ics.m.
% - The returned launch field is A_xy = A_1 + A_2 + noise in the propagated
%   envelope convention A_S, so overlapping beams interfere through
%   |A_1 + A_2|^2 rather than by adding two separate intensity maps.
%
% Inputs:
% x_offset,y_offset    : center of beam 1 [m]
% x_offset_beam2,y_offset_beam2  : center of beam 2 [m]
% w0 : Gaussian 1/e^2 intensity radius [m] for the no-OAM beam core.
%      For nonzero OAM it stays the Gaussian scale inside the simple vortex surrogate, not the final ring radius.
% i_laser_peak         : peak intensity target for beam 1 [W/m^2]
%                        (field amplitude uses sqrt(i_laser_peak))
%                        If t_profile is chirped and energy-normalized in
%                        define_time_ics, this is a TL-equivalent scale
%                        and not necessarily the achieved temporal peak.
% i_laser_peak_beam2       : peak intensity of beam 2 [W/m^2] (0 disables)
% dkx_offset,dky_offset      : transverse k offsets for beam 1 [rad/m]
% dkx_offset_beam2,dky_offset_beam2    : transverse k offsets for beam 2 [rad/m]
% (applied in A_S as exp(+i(dkx(x-x0)+dky(y-y0))))
% t_profile            : temporal envelope vector of length Nt from define_time_ics;
% noise_amplitude      : standard deviation of each independent Gaussian
%                        component of the added complex field noise
%                        (real and imaginary, i.e. I/Q), in the same units
%                        as A_xy [sqrt(W/m^2)].
%                        Implemented as
%                        noise = noise_amplitude * (randn + 1i*randn), so
%                        rms(abs(noise)) = sqrt(2)*noise_amplitude
% oam_charge1          : scalar OAM charge for beam 1 (=0 disables);
%                        integer values are recommended, sign sets handedness
% oam_charge_beam2          : scalar OAM charge for beam 2 (=0 disables);
%                        integer values are recommended, sign sets handedness
% x2_d, y2_d           : same-size 2D coordinate arrays used for spatial
%                        construction (normally ndgrid outputs)
% rng_seed (optional)   : optional local RNG seed for IC noise.
%                        When provided after y2_d and noise is enabled,
%                        this function seeds RNG locally and restores
%                        prior state on exit.
%
% Outputs:
% A_xy(x,y,t)          : launch field in the propagated-envelope
%                        convention A_S [sqrt(W/m^2)]
%                        solver intensity is I = |A_xy|^2 [W/m^2]
%
% OAM caveat:
% For a beam with nonzero oam_charge1 or oam_charge_beam2, the radial prefactor
% drives the initial on-axis intensity of that beam to zero. In that case the
% corresponding i_laser_peak amplitude scale is not the achieved max
% intensity unless an additional renormalization step is applied.
% The simple vortex surrogate here is also not power-normalized across
% different |l| values, so equal launched energy or equal ring peak needs
% a separate normalization outside this helper.
% Exact sampled-peak calibration is only guaranteed for the Gaussian no-OAM
% case when that beam center lands on sampled transverse nodes and the
% temporal peak of t_profile lands on a sampled time node.
% The same "amplitude-scale" caveat also applies when chirp broadening uses
% energy-preserving normalization (nonzero |beta_chirp| in define_time_ics).
%==========================================================================

  % Interface and validation:
  % - rng_seed is optional; leave it empty to use the current RNG state for
  %   the local noise draw.
  % - x2_d/y2_d and t_profile must already match the caller-owned launch
  %   grid.
  % - OAM charges are passed explicitly at this top-level call
  %   surface; use 0 in cerupp.m to disable OAM on an active beam, while
  %   beam activity still follows i_laser_peak and i_laser_peak_beam2.
  if nargin < 18 || isempty(rng_seed)
      rng_seed = [];
  end
  if ~ismatrix(x2_d) || ~ismatrix(y2_d) || ~isequal(size(x2_d), size(y2_d))
      error('build_spatiotemporal_ics:InvalidSpatialGridShape', ...
          'x2_d and y2_d must be same-size 2D arrays.');
  end
  if ~(isnumeric(t_profile) && isvector(t_profile) && ~isempty(t_profile) && ...
          all(isfinite(t_profile(:))))
      error('build_spatiotemporal_ics:InvalidTemporalProfile', ...
          't_profile must be a nonempty numeric vector with all finite entries.');
  end
  if ~(isscalar(w0) && isfinite(w0) && (w0 > 0))
      error('build_spatiotemporal_ics:InvalidW0', 'w0 must be finite and > 0. Got %g.', w0);
  end
  if ~(isscalar(i_laser_peak) && isnumeric(i_laser_peak) && isreal(i_laser_peak) && ...
          isfinite(i_laser_peak) && (i_laser_peak > 0))
      error('build_spatiotemporal_ics:InvalidBeam1Intensity', ...
          'beam 1 intensity must be a finite real scalar > 0. Got %s.', mat2str(i_laser_peak));
  end
  if ~(isscalar(i_laser_peak_beam2) && isnumeric(i_laser_peak_beam2) && ...
          isreal(i_laser_peak_beam2) && isfinite(i_laser_peak_beam2) && ...
          (i_laser_peak_beam2 >= 0))
      error('build_spatiotemporal_ics:InvalidBeam2Intensity', ...
          'beam 2 intensity must be a finite real scalar >= 0. Got %s.', mat2str(i_laser_peak_beam2));
  end
  if ~(isscalar(noise_amplitude) && isnumeric(noise_amplitude) && ...
          isreal(noise_amplitude) && isfinite(noise_amplitude) && ...
          (noise_amplitude >= 0))
      error('build_spatiotemporal_ics:InvalidNoiseAmplitude', ...
          'noise_amplitude must be a finite real scalar >= 0. Got %s.', mat2str(noise_amplitude));
  end
  if ~isempty(rng_seed)
      seed_max = double(intmax('uint32'));
      seed_val = double(rng_seed);
      if ~(isscalar(rng_seed) && isnumeric(rng_seed) && isreal(rng_seed) && ...
              isfinite(seed_val) && (seed_val >= 0) && (seed_val <= seed_max) && ...
              (seed_val == floor(seed_val)))
          error('build_spatiotemporal_ics:InvalidNoiseSeed', ...
              'rng_seed must be a finite integer scalar in [0, %u]. Got %s.', ...
              uint32(seed_max), mat2str(rng_seed));
      end
  end
  if isempty(oam_charge1)
      error('build_spatiotemporal_ics:MissingOamCharge1', ...
          'oam_charge1 must be provided explicitly; use 0 in cerupp.m to disable beam-1 OAM.');
  end
  if isempty(oam_charge_beam2)
      error('build_spatiotemporal_ics:MissingOamChargeBeam2', ...
          'oam_charge_beam2 must be provided explicitly; use 0 in cerupp.m to disable beam-2 OAM.');
  end
  if ~(isscalar(oam_charge1) && isnumeric(oam_charge1) && isreal(oam_charge1) && isfinite(oam_charge1))
      error('build_spatiotemporal_ics:InvalidOamCharge1', ...
          'oam_charge1 must be a finite real scalar; got %s.', mat2str(oam_charge1));
  end
  if (i_laser_peak_beam2 > 0) && ...
          ~(isscalar(oam_charge_beam2) && isnumeric(oam_charge_beam2) && ...
            isreal(oam_charge_beam2) && isfinite(oam_charge_beam2))
      error('build_spatiotemporal_ics:InvalidOamChargeBeam2', ...
          ['oam_charge_beam2 must be a finite real scalar whenever beam 2 is active; ' ...
           'got %s.'], mat2str(oam_charge_beam2));
  end

  % Temporal profile as 3D array for broadcasting.
  t_profile3_d= reshape(t_profile, [1 1 numel(t_profile)]);
  zero_field = zeros([size(x2_d), numel(t_profile)], 'like', t_profile3_d);
  % After the top-level explicit OAM-input checks above, build each beam
  % only when its intensity scale is active so a disabled beam returns
  % zero_field directly.
  beam1 = build_one_beam_component_local( ...
      i_laser_peak, x_offset, y_offset, dkx_offset, dky_offset, ...
      oam_charge1, w0, x2_d, y2_d, t_profile3_d, zero_field, false);
  beam2 = build_one_beam_component_local( ...
      i_laser_peak_beam2, x_offset_beam2, y_offset_beam2, ...
      dkx_offset_beam2, dky_offset_beam2, oam_charge_beam2, ...
      w0, x2_d, y2_d, t_profile3_d, zero_field, true);

  % Additive complex Gaussian field noise.
  % Guard RNG draws so noise_amplitude == 0 has no RNG stream mutation side effects.
  rng_state_restore = [];
  if noise_amplitude > 0
      if ~isempty(rng_seed)
          rng_prev_state = rng;
          rng(double(rng_seed), 'twister');
          rng_state_restore = onCleanup(@() rng(rng_prev_state));
      end
      noise_prototype = real(beam1);
      noise_amp = cast(noise_amplitude, 'like', noise_prototype);
      noise_real = randn(size(beam1), 'like', noise_prototype);
      noise_imag = randn(size(beam1), 'like', noise_prototype);
      noise = noise_amp .* complex(noise_real, noise_imag);
  end

  % Combine directly in propagated-variable convention.
  if noise_amplitude > 0
      A_xy = beam1 + beam2 + noise;
  else
      A_xy = beam1 + beam2;
  end

end

function beam = build_one_beam_component_local( ...
        i_laser_peak, x_offset, y_offset, dkx_offset, dky_offset, ...
        oam_charge, w0, x2_d, y2_d, t_profile3_d, zero_field, allow_zero_disable)
% Build one launched beam component with optional tilt and OAM.

  if allow_zero_disable && (i_laser_peak == 0)
      beam = zero_field;
      return;
  end

  % Keep all phase factors in the same numeric class as the caller-owned
  % temporal profile so the launch field stays type-consistent.
  phase_unit = cast(1i, 'like', real(t_profile3_d(1)));

  % Convert the requested peak intensity scale into the field amplitude,
  % shift the transverse coordinates onto this beam center, and build the
  % default Gaussian spatial envelope exp(-r^2/w0^2).
  amplitude = sqrt(i_laser_peak);
  x_shift = x2_d - x_offset;
  y_shift = y2_d - y_offset;
  r_sq = x_shift.^2 + y_shift.^2;
  beam_xy = exp(-r_sq / (w0^2));

  if oam_charge ~= 0

      % For nonzero OAM, convert that Gaussian into the usual vortex-like
      % launch profile with the radial prefactor and azimuthal phase built
      % around the shifted beam center.
      r = sqrt(r_sq);
      phi = atan2(y_shift, x_shift);
      beam_xy = (sqrt(2) * r / w0).^abs(oam_charge) .* beam_xy;
      beam_xy = beam_xy .* exp(+phase_unit * oam_charge * phi);
  end

  if (dkx_offset ~= 0) || (dky_offset ~= 0)

      % Apply the requested transverse launch tilt as a plane-wave phase
      % referenced to the same beam center.
      beam_xy = beam_xy .* exp(+phase_unit * (dkx_offset * x_shift + dky_offset * y_shift));
  end

  % Combine the spatial beam with the caller-owned temporal envelope to
  % build one full spatiotemporal launch component A(x,y,t).
  beam = amplitude .* beam_xy .* t_profile3_d;
end
