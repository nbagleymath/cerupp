function [w, exp_clamp_count, clamp_info] = plasma_keldysh_eval( ...
        i_vals, w_ion_interp_fn, opts)
%PLASMA_KELDYSH_EVAL Evaluate the runtime Keldysh rate law on intensity samples.
% Purpose:
% - Evaluate the active per-neutral W_ion(I) law on the intensity
%   samples requested by the plasma and OFI-based NLA kernels.
% - Keep the runtime math explicit while leaving lookup-table generation
%   in plasma_keldysh_setup.build_runtime_cfg_from_setup(...) and the
%   default interpolation/clamp choices in
%   propagation_support.build_default_keldysh_eval_opts_local(...).
% - Invalid intensity input or runtime-evaluation failure remains a hard
%   error. This helper either returns a valid W_ion(I) array or throws, so
%   the plasma/NLA callers do not have to branch on a separate soft-fail
%   status after every evaluation.
%
% Runtime path map:
% - plasma_keldysh_setup.build_runtime_cfg_from_setup(...) installs the
%   chosen direct per-neutral W_ion(I) handle and its default intensity
%   window.
% - plasma_keldysh_eval(...) applies the live low/high query policy and
%   then calls that handle on the surviving samples.
% - The later plasma source and OFI-based NLA paths multiply this same
%   W_ion(I) law by the selected density scale or remaining-neutral factor;
%   that weighting is not applied inside this helper.
% - Derived sigma_K,eff / beta_eff_* diagnostics are built elsewhere from
%   this same W_ion(I) law; they are not alternate runtime laws here.
%
% Runtime W_ion(I) policy by knob:
% - Below keldysh_zero_rate_below: W_ion(I)=0.
% - Between keldysh_zero_rate_below and keldysh_lut_i_global_min:
%   W_ion(I)=0.
% - Between keldysh_lut_i_global_min and keldysh_lut_i_global_max: use the
%   lookup/interpolant.
% - Above keldysh_lut_i_global_max:
%     clamp_w_interp=true  -> keep the top LUT rate for all higher
%                             intensities.
%     clamp_w_interp=false -> let the installed W_ion(I) law decide above
%                             the LUT range; with the default LUT-backed
%                             law, that still means values are held at the
%                             LUT upper edge.
% - keldysh_lut_i_roi_min and keldysh_lut_i_roi_max only control where the
%   LUT is sampled more densely; they do not change this runtime policy.
%
% Outputs:
% - w              : per-neutral runtime OFI law W_ion(I) [s^-1]
%                    evaluated at each query sample
% - exp_clamp_count: returned for interface consistency; it stays zero on
%                    the direct-W runtime path
% - clamp_info     : intensity-clamp counts plus exp_* return fields; on
%                    the direct-W runtime path those exp_* fields stay
%                    zero/NaN because no exponential reconstruction is
%                    done here
%
% Helper map:
% - throw_keldysh_eval_failure_local   : unify hard-fail reporting
% - struct_utils.opt_struct_field      : read optional scalar/config fields
% - validate_nonnegative_intensity_query_local
%                                      : enforce the physical intensity
%                                        domain before runtime evaluation

    % A. Resolve the direct-W lookup controls.
    if (nargin < 3) || isempty(opts) || ~isstruct(opts)
        opts = struct();
    end

    if isempty(w_ion_interp_fn)
        throw_keldysh_eval_failure_local( ...
            'NO_W_INTERP', ...
            'Dynamic Keldysh runtime requires W_ion_interp_fn.');
    end

    % These setup-owned controls define the interpolation window plus the
    % low/high query handling wrapped around the direct W_ion(I) call.
    i_min = struct_utils.opt_struct_field(opts, 'I_min', NaN, 'treat_empty_as_missing', true);
    i_max = struct_utils.opt_struct_field(opts, 'I_max', NaN, 'treat_empty_as_missing', true);
    i_zero_below = struct_utils.opt_struct_field( ...
        opts, 'I_zero_below', i_min, 'treat_empty_as_missing', true);
    clamp_w_interp = logical(struct_utils.opt_struct_field( ...
        opts, 'clamp_w_interp', true, 'treat_empty_as_missing', true));
    w_min_clamp_value = double(struct_utils.opt_struct_field( ...
        opts, 'W_min_clamp_value', 0, 'treat_empty_as_missing', true));
    w_max_clamp_value = double(struct_utils.opt_struct_field( ...
        opts, 'W_max_clamp_value', w_min_clamp_value, 'treat_empty_as_missing', true));

    % B. Record zero-floor, below-LUT, and high-edge query counts, then
    % build the guarded intensity surface that the live W_ion(I) handle
    % will actually see.
    validate_nonnegative_intensity_query_local(i_vals);
    iq_raw = double(i_vals);
    clamp_info = struct( ...
        'zero_count', 0, ...
        'low_count', 0, ...
        'high_count', 0, ...
        'max_I_raw', 0, ...
        'exp_clamped_count', 0, ...
        'exp_raw_min', NaN, ...
        'exp_raw_max', NaN, ...
        'exp_raw_max_abs', NaN, ...
        'I_at_exp_max_abs', NaN);
    if ~isempty(iq_raw)
        clamp_info.max_I_raw = max(iq_raw(:));
    end
    zero_mask = false(size(iq_raw));
    low_mask = false(size(iq_raw));
    high_mask = false(size(iq_raw));
    iq = iq_raw;
    if isfinite(i_zero_below)
        zero_mask = (iq_raw < i_zero_below);
        clamp_info.zero_count = nnz(zero_mask);
    end
    if isfinite(i_min)
        low_mask = (iq_raw < i_min) & ~zero_mask;
        clamp_info.low_count = nnz(low_mask);
    end
    if isfinite(i_max)
        high_mask = (iq_raw > i_max);
        clamp_info.high_count = nnz(high_mask);
        if clamp_w_interp
            iq = min(iq, i_max);
        end
    end
    if ~isfinite(w_min_clamp_value) || (w_min_clamp_value < 0)
        w_min_clamp_value = 0;
    end
    if ~isfinite(w_max_clamp_value) || (w_max_clamp_value < 0)
        w_max_clamp_value = w_min_clamp_value;
    end

    w = NaN(size(iq));
    exp_clamp_count = 0;

    % C. Evaluate the live direct W_ion(I) law after the shared
    % query/clamp bookkeeping above has prepared the evaluation surface.
    w = eval_direct_w_mode_local( ...
        w_ion_interp_fn, iq, zero_mask, low_mask, high_mask, ...
        clamp_w_interp, w_min_clamp_value, w_max_clamp_value);

    % E. Final validity pass plus explicit zeroing below the requested
    % floor and below the LUT minimum.
    w = real(double(w));
    bad_nonfinite = ~isfinite(w);
    bad_negative = (w < 0);
    if any(bad_nonfinite(:)) || any(bad_negative(:))
        if any(bad_nonfinite(:))
            throw_keldysh_eval_failure_local( ...
                'NONFINITE_W_INVALID', ...
                sprintf('nonfinite_count=%d, negative_count=%d', ...
                    nnz(bad_nonfinite), nnz(bad_negative)));
        else
            throw_keldysh_eval_failure_local( ...
                'NEGATIVE_W_INVALID', ...
                sprintf('negative_count=%d', nnz(bad_negative)));
        end
    end
    if any(zero_mask(:))
        w(zero_mask) = 0;
    end
    if any(low_mask(:) & ~zero_mask(:))
        w(low_mask & ~zero_mask) = 0;
    end
end

function w = eval_direct_w_mode_local( ...
        w_ion_interp_fn, iq, zero_mask, low_mask, high_mask, ...
        clamp_w_interp, w_min_clamp_value, w_max_clamp_value)
% Evaluate the direct W_ion(I) handle after the shared query validation.

    w = NaN(size(iq));
    try
        % Queries below I_min are forced to zero before the direct law is
        % called, so the low-intensity side never borrows the first LUT
        % rate. clamp_w_interp only changes the high-intensity side:
        % either hold the top LUT rate here or let the installed W_ion(I)
        % law handle values above the LUT range.
        low_zero_mask = low_mask & ~zero_mask;
        within_mask = true(size(iq));
        if clamp_w_interp
            within_mask = ~(zero_mask | low_zero_mask | high_mask);
            if any(high_mask(:))
                w(high_mask) = w_max_clamp_value;
            end
        else
            within_mask = ~(zero_mask | low_zero_mask);
        end
        if any(within_mask(:))
            % This calls the setup-installed W_ion_interp_fn handle. Setup
            % installs that handle by either loading the MAT lookup cache
            % derived from keldysh_lookup_csv_name or rebuilding the merged
            % coarse/ROI lookup in
            % plasma_keldysh_setup_support.plasma_keldysh_finish_runtime_cfg_local(...).
            w_raw = w_ion_interp_fn(iq(within_mask));
            if numel(w_raw) ~= nnz(within_mask)
                throw_keldysh_eval_failure_local( ...
                    'SIZE_MISMATCH_W', ...
                    sprintf('numel(W_raw)=%d, nnz(within_mask)=%d.', numel(w_raw), nnz(within_mask)));
            end
            w(within_mask) = double(w_raw(:));
        end
        if any(zero_mask(:))
            w(zero_mask) = 0;
        end
        if any(low_zero_mask(:))
            w(low_zero_mask) = 0;
        end
    catch me
        if is_keldysh_eval_failure_identifier_local(me.identifier)
            rethrow(me);
        end
        throw_keldysh_eval_failure_local( ...
            'EXCEPTION_W', ...
            sprintf('%s: %s', char(me.identifier), char(me.message)), ...
            me);
    end
end

function throw_keldysh_eval_failure_local(reason, detail, cause_exception)
%THROW_KELDYSH_EVAL_FAILURE_LOCAL Raise one runtime-evaluation error.
% Runtime failures here use the CerUPP:KeldyshEvalFailed:* identifier
% family, and the suffix distinguishes missing/invalid input, invalid
% W_ion(I), or an inner evaluation exception.

    failure_id = keldysh_eval_failure_identifier_local(reason);
    failure_msg = sprintf('Keldysh evaluation failed (%s). Detail: %s', ...
        normalize_keldysh_eval_text_local(reason), ...
        normalize_keldysh_eval_text_local(detail));
    if nargin < 3 || isempty(cause_exception)
        error(failure_id, '%s', failure_msg);
    end
    failure = MException(failure_id, '%s', failure_msg);
    failure = addCause(failure, cause_exception);
    throwAsCaller(failure);
end

function failure_id = keldysh_eval_failure_identifier_local(reason)
%KELDYSH_EVAL_FAILURE_IDENTIFIER_LOCAL Map local failure reasons to child identifiers.

    prefix = 'CerUPP:KeldyshEvalFailed';
    switch upper(normalize_keldysh_eval_text_local(reason))
        case 'NO_W_INTERP'
            suffix = 'MissingInterpHandle';
        case 'INVALID_INTENSITY_CLASS'
            suffix = 'InvalidIntensityClass';
        case 'COMPLEX_INTENSITY'
            suffix = 'ComplexIntensity';
        case 'NONFINITE_INTENSITY'
            suffix = 'NonfiniteIntensity';
        case 'NEGATIVE_INTENSITY'
            suffix = 'NegativeIntensity';
        case 'SIZE_MISMATCH_W'
            suffix = 'SizeMismatchW';
        case 'NONFINITE_W_INVALID'
            suffix = 'NonfiniteW';
        case 'NEGATIVE_W_INVALID'
            suffix = 'NegativeW';
        case 'EXCEPTION_W'
            suffix = 'InnerException';
        otherwise
            suffix = 'Failure';
    end
    failure_id = [prefix ':' suffix];
end

function tf = is_keldysh_eval_failure_identifier_local(identifier)
%IS_KELDYSH_EVAL_FAILURE_IDENTIFIER_LOCAL Accept the full Keldysh-eval failure family.

    prefix = 'CerUPP:KeldyshEvalFailed';
    legacy_prefix = 'CerUPP:KeldyshEvalInterpFailed';
    tf = ischar(identifier) && ...
        (strncmp(identifier, prefix, numel(prefix)) || ...
         strncmp(identifier, legacy_prefix, numel(legacy_prefix)));
end

function txt = normalize_keldysh_eval_text_local(value)
%NORMALIZE_KELDYSH_EVAL_TEXT_LOCAL Backward-compatible text coercion helper.

    if ischar(value)
        txt = value;
    elseif exist('isstring', 'builtin') && isstring(value)
        if isempty(value)
            txt = '';
        else
            txt = char(value(1));
        end
    elseif isnumeric(value) || islogical(value)
        txt = num2str(value);
    elseif isempty(value)
        txt = '';
    else
        txt = class(value);
    end
    if isempty(txt)
        txt = '<empty>';
    end
end

function validate_nonnegative_intensity_query_local(i_vals)
%VALIDATE_NONNEGATIVE_INTENSITY_QUERY_LOCAL Enforce the physical query domain.
% This evaluator only accepts real, finite, nonnegative intensity samples.
% Complex envelopes and sign-carrying field variables must be converted to
% intensity before reaching this runtime rate-law helper.

    if ~isnumeric(i_vals)
        throw_keldysh_eval_failure_local( ...
            'INVALID_INTENSITY_CLASS', ...
            sprintf('Expected numeric intensity input, got %s.', class(i_vals)));
    end
    if ~isreal(i_vals)
        throw_keldysh_eval_failure_local( ...
            'COMPLEX_INTENSITY', ...
            'Intensity input must remain real in the live Keldysh evaluation path.');
    end
    bad_nonfinite = ~isfinite(i_vals);
    if any(bad_nonfinite(:))
        bad_idx = find(bad_nonfinite, 1, 'first');
        throw_keldysh_eval_failure_local( ...
            'NONFINITE_INTENSITY', ...
            sprintf('Non-finite intensity at linear index %d.', bad_idx));
    end
    bad_negative = (i_vals < 0);
    if any(bad_negative(:))
        bad_idx = find(bad_negative, 1, 'first');
        throw_keldysh_eval_failure_local( ...
            'NEGATIVE_INTENSITY', ...
            sprintf('Negative intensity at linear index %d (value=%g).', ...
                bad_idx, double(i_vals(bad_idx))));
    end
end
