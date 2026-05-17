%==========================================================================
% CALCULATE_MEDIUM_PROPERTIES_Z
%==========================================================================
% Medium/operator bundle builder for the current medium state.
% This helper computes three layers inline:
%   1) z-invariant medium prefactors and coefficients,
%   2) (if enabled and desired) z-dependent medium/geometry surface maps,
%   3) current-dz half-step factors (linear half-step and guiding phase).
% Keep any z-dependent medium changes here, where the medium maps, the
% scalar spectral coefficients, and the current-dz operators stay visible
% in one place instead of being split across tiny local builders.
% If a future medium also changes plasma/NLA material parameters with z,
% return those updated values here too. cerupp.m refreshes the dependent
% plasma/Keldysh/NLA runtime state at this same rebuild point so the full
% material state stays in sync instead of refreshing only the optical maps.
% At present the built-in rebuild trigger only detects n and n2 changes.
% The live driver keeps allow_z_dependent_keldysh=false by default, so
% these z-dependent rebuilds normally change only the optical medium/
% operator bundle while dynamic Keldysh stays on its setup-time runtime
% cfg. If you want true z-dependent Keldysh physics, hardcode the desired
% z-varying Keldysh material inputs here and then enable
% allow_z_dependent_keldysh in cerupp.m.
%
% INPUTS:
% - Positional interface only.
% - The trailing required controls are dz,
%   nonparaxial_diffraction_order, m_plasma_kg, z_curr, and
%   resolved_linear_medium_name.
% - mask_f_w stays in the positional ABI because the built-in medium
%   builder uses it so masked-out omega bins do not participate in the
%   low-k denominator guard or the denominator-sensitive diffraction terms.
% - medium_builder_custom_args is the one optional trailing scalar struct
%   for explicit medium-builder custom inputs. This helper reads that
%   struct directly on each call.
% - Keep later per-step physics inputs in major_step_custom_args inside
%   cerupp.m. This medium builder returns medium/material data together
%   with the current-dz operator factors built from that state.
% - keldysh_material_state_update and medium_builder_custom_outputs are
%   returned below; they are not caller-supplied input arguments.
% - High-level input groups:
%   physical constants           : c, ep0, me, qe, hbar
%   diagnostic thresholds        : i_laser_peak, i_fil_cutoff,
%                                  i_fil_cutoff_vis, rho_fil_cutoff
%   geometry/grid inputs         : x, y, core_radius, kperp
%   spectral/carrier inputs      : lambda_window, omega_window,
%                                  lambda_fund, omega_fund
%   material / plasma / MPI      : n2_kerr, frozen_cfg_rho_nt_m3,
%                                  frozen_cfg_rho_nt_keldysh_norm_m3,
%                                  frozen_cfg_ui, frozen_cfg_sigma_k_vec,
%                                  frozen_cfg_ofi_k_orders, tau_c,
%                                  frozen_cfg_alpha_recombine, m_plasma_kg
%   operator / stepping controls : dz, nonparaxial_diffraction_order
%   caller-passed mask ABI       : mask_f_w
% - dz is required and must be a finite scalar > 0.
% - nonparaxial_diffraction_order must already be one of {2,4,6,8}.
% - The driver reuses the returned half-step factors only when the current
%   dz matches the last built operator dz and the medium state does not rebuild.
%   When either of those conditions changes, the driver rebuilds the factors.
% - For orders >2, the extra nonparaxial corrections enter only through
%   diffraction_dispersion_matrix. qomega_3d stays the same omega-only
%   Kerr prefactor for every supported order.
%
% Example:
% [diffraction_dispersion_matrix, guiding_matrix, qomega_3d, ...] = ...
%     calculate_medium_properties_z(c, ep0, me, qe, hbar, ...
%         i_laser_peak, i_fil_cutoff, i_fil_cutoff_vis, rho_fil_cutoff, ...
%         x, y, core_radius, lambda_window, omega_window, ...
%         lambda_fund, omega_fund, n2_kerr, ...
%         frozen_cfg_rho_nt_m3, frozen_cfg_rho_nt_keldysh_norm_m3, ...
%         frozen_cfg_ui, frozen_cfg_sigma_k_vec, frozen_cfg_ofi_k_orders, ...
%         tau_c, frozen_cfg_alpha_recombine, kperp, mask_f_w, dz, ...
%         nonparaxial_diffraction_order, m_plasma_kg, z_curr, resolved_linear_medium_name, ...
%         struct());

%
% OUTPUTS:
% diffraction_dispersion_matrix : linear (k_x,k_y,omega) phase-rate operator
%                                 used directly in exp(-1i * ... * dz/2)
% guiding_matrix                : k_guid(x,y,omega) [1/m]
% qomega_3d                     : Kerr prefactor (FEE form), omega-only [1*1*N].
%                                Higher-order nonparaxial corrections stay
%                                in diffraction_dispersion_matrix rather
%                                than in this Kerr prefactor.
% sigma_vec, sigma_aval_omega_fund : Drude IB coefficient sigma(omega) [m^2] on the
%                                absolute spectral grid omega_window, and the
%                                reduced real scalar avalanche coefficient
%                                Re[sigma(omega_fund)] used for carrier-frequency
%                                avalanche accounting.
%                                Plasma coupling is applied in frequency domain as
%                                rhs_plasma(omega) = -0.5*sigma(omega)*FFT_t{rho(t).*A(t)}.
%                                Equivalent time-domain view is a convolution operator.
% plas_dens_crit                : plasma critical density rho_crit =
%                                ep0 * m_plasma_kg * omega_fund^2 / qe^2
% frozen_cfg_rho_nt_m3         : frozen neutral-site density rho_nt [m^-3]
%                                used as the stored material-density
%                                reference and in static MPI normalization.
%                                plasma_runtime_cfg.neutral_reservoir_m3
%                                later resolves the live OFI source
%                                reservoir from this rho_nt value together
%                                with the top-level source-side reservoir
%                                input rho_neutral_supply, so the
%                                propagated OFI reservoir can be smaller
%                                than this stored material reference.
% frozen_cfg_rho_nt_keldysh_norm_m3
%                              : frozen Keldysh-normalization density [m^-3].
% frozen_cfg_ui                : frozen material ionization energy Ui [J]
% frozen_cfg_alpha_recombine   : frozen recombination coefficient [m^3/s]
% frozen_cfg_sigma_k_vec,
% frozen_cfg_ofi_k_orders      : frozen MPI coefficient/order family
% beta_k_vec                   : multiphoton absorption coefficients beta_K
% mask_2_d                     : 2-D spatial mask (x,y) for nonlinear terms
% core_idx                     : linear indices of (x,y) pixels inside the nonlinear core (mask_2_d>0).
%                                If a z-dependent medium changes the nonlinear support,
%                                update mask_2_d and core_idx together here; cerupp.m
%                                threads the rebuilt core_idx forward to the current-step
%                                diagnostics and the final Section 6A postprocessing pass.
%                                The built-in Kerr/plasma/NLA chain only acts on
%                                that returned mask/core index set, so any custom
%                                nonlinear support outside mask_2_d is ignored
%                                unless this helper expands mask_2_d/core_idx too.
% lin_index_3d, nl_index_3d    : optical surfaces returned by the selected
%                                medium builder. lin_index_3d is the full
%                                x-y-spectral linear-index cube, while
%                                nl_index_3d is the 2-D Kerr map used by
%                                the nonlinear step. Both built-in YAG and
%                                built-in AIR use the Rod_on_Air optical-
%                                surface builder here.
% n_sell                       : 1xN row vector of reference Sellmeier index over lambda_window
%                                (used for scalar/spectral prefactors; x,y-independent)
% n_sell_fund                  : reference Sellmeier index at lambda_fund (physics reference / omega_fund)
%                                n_sell/n_sell_fund are the reference/core indices used in
%                                k(omega), k_shift, Q(omega), sigma(omega); lin_index_3d
%                                is the full spatial index map.
% n_omega_fund_xy             : lin_index_3d slice at omega_fund [Nx, Ny]
% vis_intensity_onset_frac      : intensity-threshold fraction i_fil_cutoff_vis/i_laser_peak.
% intensity_onset_frac          : intensity-threshold fraction i_fil_cutoff/i_laser_peak.
% rho_onset_frac               : rho_fil_cutoff / frozen_cfg_rho_nt_m3
% lin_half_factor_step         : current-dz linear half-step factor
% guiding_phase_step           : current-dz guiding half-step factor, or []
%                                when the guiding term is identically zero
%                                and the caller should skip that multiply
% inv_vg_fund                  : first dispersion derivative at omega_fund,
%                                inv_vg_fund = eta_1|omega_fund = dk/domega|omega_fund = 1/v_g [s/m],
%                                i.e. the carrier inverse group velocity
% medium_surface_builder_tag   : explicit tag naming the current built-in
%                                transverse medium-surface builder so
%                                cerupp.m can decide whether a later
%                                z-dependent preview/delta check is
%                                available for this medium path
% keldysh_material_state_update : optional built-in grouped material
%                                update for later dynamic-Keldysh refresh
%                                hooks in cerupp.m
% medium_builder_custom_outputs : optional user extension output struct.
%                                The built-in driver leaves this reserved
%                                for future explicit custom consumers.
%==========================================================================
function [diffraction_dispersion_matrix, guiding_matrix, qomega_3d, ...
          sigma_vec, sigma_aval_omega_fund, plas_dens_crit, ...
          frozen_cfg_rho_nt_m3, frozen_cfg_rho_nt_keldysh_norm_m3, ...
          frozen_cfg_ui, frozen_cfg_alpha_recombine, ...
          frozen_cfg_sigma_k_vec, frozen_cfg_ofi_k_orders, beta_k_vec, mask_2_d,core_idx, ...
          lin_index_3d, nl_index_3d, n_sell, n_sell_fund, n_omega_fund_xy, ...
          vis_intensity_onset_frac, intensity_onset_frac, rho_onset_frac, ...
          lin_half_factor_step, guiding_phase_step, inv_vg_fund, ...
          medium_surface_builder_tag, ...
          keldysh_material_state_update, ...
          medium_builder_custom_outputs]= ...
    calculate_medium_properties_z(c, ep0, me, qe, hbar, ...
    i_laser_peak, i_fil_cutoff, i_fil_cutoff_vis, rho_fil_cutoff, ...
    x, y, core_radius, lambda_window, omega_window, ...
    lambda_fund, omega_fund, n2_kerr, ...
    frozen_cfg_rho_nt_m3, frozen_cfg_rho_nt_keldysh_norm_m3, frozen_cfg_ui, ...
    frozen_cfg_sigma_k_vec, frozen_cfg_ofi_k_orders, tau_c, frozen_cfg_alpha_recombine_in, kperp, ...
    mask_f_w, dz, nonparaxial_diffraction_order, m_plasma_kg, z_curr, resolved_linear_medium_name, medium_builder_custom_args)

    % medium_builder_custom_args is the optional extra-input struct for
    % this medium builder. The built-in YAG/AIR path leaves both
    % keldysh_material_state_update and medium_builder_custom_outputs
    % empty unless a user adds an explicit custom block below.
    if nargin < 32 || isempty(medium_builder_custom_args)
        medium_builder_custom_args = struct();
    end
    if ~isstruct(medium_builder_custom_args) || ~isscalar(medium_builder_custom_args)
        error('calculate_medium_properties_z:InvalidMediumBuilderCustomArgs', ...
            'medium_builder_custom_args must be a scalar struct when supplied.');
    end
    keldysh_material_state_update = struct();
    medium_builder_custom_outputs = struct();
    medium_surface_builder_tag = '';

    if ~(isscalar(frozen_cfg_rho_nt_keldysh_norm_m3) && ...
            isnumeric(frozen_cfg_rho_nt_keldysh_norm_m3) && ...
            isreal(frozen_cfg_rho_nt_keldysh_norm_m3) && ...
            isfinite(frozen_cfg_rho_nt_keldysh_norm_m3) && ...
            (double(frozen_cfg_rho_nt_keldysh_norm_m3) > 0))
        error('calculate_medium_properties_z:InvalidKeldyshNormDensity', ...
            'frozen_cfg_rho_nt_keldysh_norm_m3 must be a finite real scalar > 0 [m^-3].');
    end
    if ~(isscalar(frozen_cfg_alpha_recombine_in) && ...
            isnumeric(frozen_cfg_alpha_recombine_in) && ...
            isreal(frozen_cfg_alpha_recombine_in) && ...
            isfinite(frozen_cfg_alpha_recombine_in) && ...
            (double(frozen_cfg_alpha_recombine_in) >= 0))
        error('calculate_medium_properties_z:InvalidAlphaRecombine', ...
            ['frozen_cfg_alpha_recombine must be a finite real scalar >= 0 ', ...
             '[m^3/s].']);
    end
    rho_nt_norm_tracks_rho_nt = abs(double(frozen_cfg_rho_nt_keldysh_norm_m3) - double(frozen_cfg_rho_nt_m3)) <= ...
        1.0e-12 * max([abs(double(frozen_cfg_rho_nt_keldysh_norm_m3)), abs(double(frozen_cfg_rho_nt_m3)), realmin('double')]);
    frozen_cfg_rho_nt_keldysh_norm_m3 = double(real(frozen_cfg_rho_nt_keldysh_norm_m3));
    frozen_cfg_alpha_recombine = double(real(frozen_cfg_alpha_recombine_in));

    % dz is the current step length used both for the returned half-step
    % factors and for any current-step medium/operator refresh.
    if ~isscalar(dz) || ~isfinite(dz) || ~isreal(dz) || (dz <= 0)
        error('calculate_medium_properties_z:InvalidDz', ...
            'dz must be a real, finite, strictly positive scalar [m].');
    end

    % Start with the scalar spectral reference medium. These quantities are
    % independent of x, y, and z, so the later surface and half-step blocks
    % only need to thread the current geometry and dz through them.
    if strcmpi(resolved_linear_medium_name, 'AIR')
        n_sell = Sellmeier_Air(lambda_window);
        n_sell_fund = Sellmeier_Air(lambda_fund);
    else
        n_sell = Sellmeier_YAG(lambda_window);
        n_sell_fund = Sellmeier_YAG(lambda_fund);
    end
    n_sell = n_sell(:).';
    if any(~isfinite(omega_window(:)))
        error('calculate_medium_properties_z:InvalidOmegaGrid', ...
            'omega_window contains non-finite values; refusing to build medium operators.');
    end
    if any(~isfinite(n_sell(:))) || ~isfinite(n_sell_fund)
        error('calculate_medium_properties_z:NonfiniteSellmeierIndex', ...
            'Sellmeier index contains non-finite values; refusing to build medium operators.');
    end
    if any(real(n_sell(:)) <= 0) || (real(n_sell_fund) <= 0)
        error('calculate_medium_properties_z:NonpositiveSellmeierIndex', ...
            'Sellmeier index must remain positive over omega_window and at omega_fund.');
    end

    % Reference propagation constant k(omega)=n(omega)*omega/c on the
    % absolute spectral grid. We then subtract real(k_pw_fund) and the
    % real first-order group-delay slope eta_1,fund*(omega_window-omega_fund),
    % so k_shift stores only the co-moving residual phase rate seen by the
    % solver after that carrier and linear slope removal.
    k_pw = n_sell .* omega_window / c;
    k_pw_fund = n_sell_fund * omega_fund / c;
    [omega_sorted, omega_sort_idx] = sort(omega_window(:).');
    k_pw_sorted = k_pw(omega_sort_idx);
    if any(diff(omega_sorted) <= 0)
        error('calculate_medium_properties_z:NonMonotoneOmegaSorted', ...
            'omega_window must contain unique increasing samples after sorting for eta_1 interpolation.');
    end

    eta1_pw_sorted = gradient(k_pw_sorted, omega_sorted);
    eta1_pw_fund = spline(omega_sorted, eta1_pw_sorted, omega_fund);
    inv_vg_fund = real(eta1_pw_fund);
    % Physical detuning from the carrier, not the driver FFT detuning grid
    % used to build omega_window.
    omega_detuning_from_fund = omega_window - omega_fund;
    k_shift = k_pw - real(k_pw_fund) - inv_vg_fund .* omega_detuning_from_fund;

    n_sell_3d = reshape(n_sell, [1 1 numel(omega_window)]);
    active_omega_support = true(numel(omega_window), 1);
    if ~isempty(mask_f_w)
        mask_f_w_vec = double(reshape(mask_f_w, [], 1));
        if numel(mask_f_w_vec) ~= numel(omega_window)
            error('calculate_medium_properties_z:InvalidMaskFWLength', ...
                'mask_f_w must have one entry per omega bin when supplied.');
        end
        if any(~isfinite(mask_f_w_vec))
            error('calculate_medium_properties_z:InvalidMaskFWValues', ...
                'mask_f_w must stay finite when supplied.');
        end
        % The stepper still propagates any omega bin whose guard weight is
        % nonzero, so the operator builder must use that same rule.
        active_omega_support = mask_f_w_vec > 0;
        if ~any(active_omega_support)
            error('calculate_medium_properties_z:EmptyActiveOmegaSupport', ...
                ['mask_f_w removes every omega bin before the medium/operator ', ...
                 'bundle can be built.']);
        end
    end
    omega_min = min(omega_window(:));
    omega_max = max(omega_window(:));
    n_sell_real = real(n_sell(:));
    if (omega_fund < omega_min) || (omega_fund > omega_max)
        [~, idx_nearest] = min(abs(omega_window - omega_fund));
        omega_nearest = omega_window(idx_nearest);
        error('calculate_medium_properties_z:OmegaFundOutOfBand', ...
            ['omega_fund=%.6e rad/s is outside simulated omega_window=[%.6e, %.6e] rad/s. ' ...
             'Nearest bin is omega_window(%d)=%.6e rad/s (|delta|=%.6e). ' ...
             'Adjust the reference frequency and/or spectral window so omega_fund lies within ' ...
             'the simulated omega_window; the nearest sampled bin is reported above for debugging.'], ...
            omega_fund, omega_min, omega_max, idx_nearest, omega_nearest, abs(omega_nearest - omega_fund));
    end

    k_pw_abs = abs(k_pw(:));
    active_k_pw_abs = k_pw_abs(active_omega_support);
    active_omega_window = omega_window(active_omega_support);
    active_n_sell_real = n_sell_real(active_omega_support);
    [~, idx_nearest_active] = min(abs(omega_window - omega_fund));
    omega_nearest_active = omega_window(idx_nearest_active);
    omega_fund_active = logical(active_omega_support(idx_nearest_active));
    active_omega_min = min(active_omega_window);
    active_omega_max = max(active_omega_window);
    if (omega_fund < active_omega_min) || (omega_fund > active_omega_max) || ~omega_fund_active
        error('calculate_medium_properties_z:OmegaFundMaskedOut', ...
            ['omega_fund=%.6e rad/s falls outside the active omega passband after mask_f_w is applied. ', ...
             'Active omega-window=[%.6e, %.6e] rad/s; nearest sampled bin is omega_window(%d)=%.6e rad/s ', ...
             'with active_mask=%d. Adjust the omega guard or spectral window so the kept passband still ', ...
             'contains omega_fund.'], ...
            omega_fund, active_omega_min, active_omega_max, idx_nearest_active, ...
            omega_nearest_active, double(omega_fund_active));
    end
    k_pw_absmax = max(active_k_pw_abs);
    k_pw_absmin = min(active_k_pw_abs);
    rel_tol_tight = struct_utils.cerupp_numeric_threshold('rel_tol_tight');
    k_min_tol = max(rel_tol_tight, 1e-9 * k_pw_absmax);
    if any(active_k_pw_abs < k_min_tol)
        error('calculate_medium_properties_z:SmallKpw', ...
            ['Detected active |k(omega)| below tolerance inside the propagated spectral support: ', ...
             'min|k|=%.3e, tol=%.3e. active omega_window[min,max]=[%.3e, %.3e] rad/s, ', ...
             'active n_sell[min,max]=[%.6g, %.6g]. Likely causes: detuning grid used instead ', ...
             'of absolute omega, omega crossing 0, or invalid Sellmeier inputs. No denominator ', ...
             'clamp fallback is applied on active bins.'], ...
            k_pw_absmin, k_min_tol, min(active_omega_window), ...
            max(active_omega_window), min(active_n_sell_real), ...
            max(active_n_sell_real));
    end

    % Spectral-guarded bins are masked out before propagation. Keep the
    % hard failure for active low-k bins, but fill the denominator-side
    % inactive bins with one benign finite reference value so masked low
    % omega edges cannot poison the diffraction operator build.
    k_pw_denom = k_pw;
    inactive_omega_support = ~active_omega_support;
    if any(inactive_omega_support)
        [~, idx_fill] = max(active_k_pw_abs);
        k_pw_fill = k_pw(active_omega_support);
        k_pw_denom(inactive_omega_support) = k_pw_fill(idx_fill);
    end
    k_pw_denom_3d = reshape(k_pw_denom, [1 1 numel(omega_window)]);

    % diff_term stores the positive magnitude of the transverse correction
    % k_perp^2/(2k) + k_perp^4/(8k^3) + ... . The operator later uses
    % k_shift - diff_term, which matches
    % sqrt(k^2-k_perp^2)-k = -k_perp^2/(2k) - k_perp^4/(8k^3) - ...
    % expanded in powers of k_perp/k. Order 2 keeps the paraxial
    % k_perp^2 term, and higher supported orders append the k_perp^4,
    % k_perp^6, and k_perp^8 corrections in that same series.
    diff_term = (kperp.^2) ./ (2 .* k_pw_denom_3d);
    if nonparaxial_diffraction_order >= 4
        diff_term = diff_term + (kperp.^4) ./ (8 .* (k_pw_denom_3d.^3));
    end
    if nonparaxial_diffraction_order >= 6
        diff_term = diff_term + (kperp.^6) ./ (16 .* (k_pw_denom_3d.^5));
    end
    if nonparaxial_diffraction_order >= 8
        diff_term = diff_term + (5 .* (kperp.^8)) ./ (128 .* (k_pw_denom_3d.^7));
    end
    diffraction_dispersion_matrix = -(reshape(k_shift, [1 1 numel(omega_window)]) - diff_term);

    % Q(omega) = (omega/c) * n_sell(omega_fund) / n_sell(omega) is the
    % omega-only Kerr prefactor used by the FEE form.
    qomega_3d = reshape((omega_window / c) .* (n_sell_fund ./ n_sell), [1 1 numel(omega_window)]);

    % rho_crit = ep0*m*omega_fund^2/qe^2 is the carrier-density scale where
    % the Drude plasma frequency matches the carrier frequency. The static
    % MPI family gives beta_K = K*hbar*omega_fund*rho_nt*sigma_K.
    plas_dens_crit = ep0 * m_plasma_kg * omega_fund^2 / qe^2;
    beta_k_vec = frozen_cfg_ofi_k_orders(:) .* hbar .* omega_fund .* frozen_cfg_rho_nt_m3 .* frozen_cfg_sigma_k_vec(:);

    % sigma(omega) is the complex Drude coefficient multiplying
    % FFT_t{rho(t).*A(t)} in the plasma source:
    %   rhs_plasma(omega) = -0.5 * sigma(omega) * FFT_t{rho(t).*A(t)}.
    % The real part gives the dissipative current, and the imaginary part
    % gives the refractive plasma phase shift.
    den = n_sell .* c .* plas_dens_crit;
    num = omega_fund .* tau_c .* (1 + cast(1i, 'like', real(omega_window(1))) .* omega_window .* tau_c);
    sigma_vec = reshape((omega_fund ./ den) .* ...
        (num ./ (1 + (omega_window.^2) .* (tau_c.^2))), [], 1);
    den_fund = n_sell_fund * c * plas_dens_crit;
    sigma_aval_raw = (omega_fund / den_fund) .* ...
        ((omega_fund * tau_c) ./ (1 + (omega_fund.^2) .* (tau_c.^2)));
    sigma_aval_omega_fund = sigma_aval_raw;
    if ~isscalar(sigma_aval_omega_fund) || ~isreal(sigma_aval_omega_fund) || ...
            ~isfinite(sigma_aval_omega_fund) || (sigma_aval_omega_fund < 0)
        error('calculate_medium_properties_z:InvalidAvalancheCarrierScalar', ...
            ['Reduced carrier-frequency avalanche coefficient Re[sigma(omega_fund)] must be ', ...
             'a finite real scalar >= 0; got %s.'], mat2str(sigma_aval_omega_fund));
    end

    vis_intensity_onset_frac = i_fil_cutoff_vis / i_laser_peak;
    intensity_onset_frac = i_fil_cutoff / i_laser_peak;
    rho_onset_frac = rho_fil_cutoff / frozen_cfg_rho_nt_m3;

    % Build the current transverse medium surface from the spectral
    % reference state. Rod_on_Air returns the x-y index maps and the core
    % mask that the Kerr/plasma/NLA chain actually uses on this step.
    [lin_index_3d, nl_index_3d, mask_2_d, medium_meta] = Rod_on_Air( ...
        x, y, n_sell, core_radius, lambda_window, n2_kerr, z_curr);
    medium_surface_builder_tag = struct_utils.req_struct_field( ...
        medium_meta, 'surface_builder_tag', ...
        'Rod_on_Air medium_meta');
    if isstring(medium_surface_builder_tag) && isscalar(medium_surface_builder_tag)
        medium_surface_builder_tag = char(medium_surface_builder_tag);
    end
    if ~(ischar(medium_surface_builder_tag) && isrow(medium_surface_builder_tag) && ...
            ~isempty(medium_surface_builder_tag))
        error('calculate_medium_properties_z:InvalidSurfaceBuilderTag', ...
            ['Rod_on_Air must return one nonempty surface_builder_tag so cerupp.m ', ...
             'can decide whether later z-dependent preview/delta checks are available.']);
    end
    core_idx = find(mask_2_d);

    % The guiding operator is the usual weak-guiding correction
    %   k_guid = (omega/c) * (n_xy^2 - n_ref^2) / (2*n_ref),
    % evaluated against the reference scalar index n_ref(omega)=n_sell.
    omega_window_3d = reshape(omega_window, [1 1 numel(omega_window)]);
    guiding_matrix = (omega_window_3d / c) .* ((lin_index_3d.^2 - n_sell_3d.^2) ./ (2 * n_sell_3d));
    [~, idx_fund] = min(abs(omega_window - omega_fund));
    n_omega_fund_xy = lin_index_3d(:,:,idx_fund);

    % Build the half-step operators applied by the split-step update:
    %   linear half-step  = exp(-1i * diffraction_dispersion_matrix * dz/2)
    %   guiding half-step = exp(+1i * guiding_matrix * dz/2).
    % When the guiding term is exactly zero, return [] so the caller can
    % skip that extra multiply instead of carrying an all-ones array.
    dz_half_linear = cast(dz / 2, 'like', diffraction_dispersion_matrix);
    lin_half_factor_step = exp((-1i) .* diffraction_dispersion_matrix .* dz_half_linear);
    if isempty(guiding_matrix) || ~any(guiding_matrix(:) ~= 0)
        guiding_phase_step = [];
    else
        dz_half_guiding = cast(dz / 2, 'like', guiding_matrix);
        guiding_phase_step = exp(1i .* dz_half_guiding .* guiding_matrix);
    end

    if rho_nt_norm_tracks_rho_nt
        frozen_cfg_rho_nt_keldysh_norm_m3 = frozen_cfg_rho_nt_m3;
    end
end
