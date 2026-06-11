function varargout = plasma_keldysh_setup_support(action, varargin)
%PLASMA_KELDYSH_SETUP_SUPPORT Owns the longer setup-side helper family for plasma_keldysh_setup.m.
% The public class keeps the setup contract and the core Keldysh math
% kernels. This helper owns the longer non-math setup machinery:
% - canonical setup-struct reads plus active/disabled runtime packaging
% - requested->effective setup rewrites and driver-control normalization
% - built-in medium/OFI family labels and branch-activity classification
% Keep physics-formula edits in plasma_keldysh_setup.m; keep setup-policy
% and packaging edits here.

    if nargin < 1 || ~(ischar(action) || (isstring(action) && isscalar(action)))
        error('plasma_keldysh_setup_support:MissingAction', ...
            'plasma_keldysh_setup_support requires a char/string action name.');
    end
    action = char(string(action));
    switch action
        case 'build_runtime_cfg_from_setup'
            [varargout{1:nargout}] = plasma_keldysh_build_runtime_cfg_from_setup_local(varargin{:});
        case 'build_runtime_signature_from_setup'
            [varargout{1:nargout}] = plasma_keldysh_build_runtime_signature_from_setup_local(varargin{:});
        case 'resolve_driver_controls'
            [varargout{1:nargout}] = plasma_keldysh_resolve_driver_controls_local(varargin{:});
        case 'medium_kind_from_spec'
            [varargout{1:nargout}] = plasma_keldysh_medium_kind_from_spec_local(varargin{:});
        case 'requested_ofi_model_name_from_spec'
            [varargout{1:nargout}] = plasma_keldysh_requested_ofi_model_name_from_spec_local(varargin{:});
        case 'attach_ofi_model_policy_labels'
            [varargout{1:nargout}] = plasma_keldysh_attach_ofi_model_policy_labels_local(varargin{:});
        case 'is_ofi_branch_active'
            [varargout{1:nargout}] = plasma_keldysh_is_ofi_branch_active_local(varargin{:});
        case 'build_runtime_cfg_disabled'
            [varargout{1:nargout}] = plasma_keldysh_build_runtime_cfg_disabled_from_setup_local(varargin{:});
        case 'record_setup_rewrite'
            [varargout{1:nargout}] = plasma_keldysh_record_setup_rewrite_local(varargin{:});
        case 'build_runtime_cfg_active'
            [varargout{1:nargout}] = plasma_keldysh_build_runtime_cfg_active_from_setup_local(varargin{:});
        otherwise
            error('plasma_keldysh_setup_support:UnknownAction', ...
                'Unknown plasma_keldysh_setup_support action "%s".', action);
    end
end

function [kcfg, run_warn_state] = plasma_keldysh_build_runtime_cfg_from_setup_local(setup_cfg, run_warn_state)
% Canonical setup reader plus active/disabled runtime-branch selection.
% This keeps the public class entry point short while the actual Keldysh
% math still lives in plasma_keldysh_setup.m.

    if nargin < 1 || ~isstruct(setup_cfg)
        error('plasma_keldysh_setup:InvalidKeldyshSetupCfg', ...
            'build_runtime_cfg_from_setup requires a struct setup_cfg.');
    end
    if nargin < 2 || ~isstruct(run_warn_state)
        error('CerUPP:InvalidRunWarnState', ...
            'build_runtime_cfg_from_setup requires an explicit struct run_warn_state.');
    end
    run_warn_state = struct_utils.ensure_warned_keys_map(run_warn_state);
    setup = plasma_setup_support.require_runtime_setup_cfg_local(setup_cfg, true);
    if ~setup.keldysh_runtime_enabled
        [kcfg, run_warn_state] = plasma_keldysh_build_runtime_cfg_disabled_from_setup_local( ...
            setup, run_warn_state);
        return;
    end
    [kcfg, run_warn_state] = plasma_keldysh_build_runtime_cfg_active_from_setup_local( ...
        setup, run_warn_state);
end

function runtime_signature = plasma_keldysh_build_runtime_signature_from_setup_local(setup_cfg)
% Build the small setup-signature record used for cache labels and reports.

    if nargin < 1 || ~isstruct(setup_cfg)
        error('plasma_keldysh_setup:InvalidKeldyshSetupCfg', ...
            'build_runtime_signature_from_setup requires a struct setup_cfg.');
    end
    setup = plasma_setup_support.require_runtime_setup_cfg_local(setup_cfg, false);
    policy = plasma_keldysh_setup.resolve_policy(struct());
    runtime_model = plasma_setup_support.build_keldysh_runtime_model_local( ...
        setup, policy, logical(setup.use_solid_state_keldysh_flag));
    runtime_signature = plasma_setup_support.build_keldysh_runtime_signature_local(runtime_model);
end

function [keldysh_ctrl, run_warn_state, setup_physics_rewrite_report] = ...
        plasma_keldysh_resolve_driver_controls_local( ...
        medium_spec, sigma_k_vec, me, run_warn_state, ...
        setup_physics_rewrite_report, ...
        record_setup_physics_rewrite_fn, init_setup_physics_rewrite_report_fn, ...
        keldysh_enabled_requested, keldysh_display_k_requested, ...
        keldysh_lookup_csv_name_requested, ...
        air_dynamic_keldysh_contract_needed, ...
        air_static_placeholder_contract_needed)
% Resolve the driver-facing Keldysh control record from the setup knobs.
% This is setup-policy machinery, not Keldysh math: it normalizes the
% user requests, chooses the built-in medium family, and records any
% required requested->effective rewrites before the runtime builder runs.

    if nargin < 12
        error('CerUPP:MissingKeldyshDriverControlInputs', ...
            ['resolve_driver_controls requires medium_spec, sigma_k_vec, me, run_warn_state, ', ...
             'setup_physics_rewrite_report, record_setup_physics_rewrite_fn, ', ...
             'init_setup_physics_rewrite_report_fn, keldysh_enabled_requested, and ', ...
             'keldysh_display_k_requested, keldysh_lookup_csv_name_requested, ', ...
             'air_dynamic_keldysh_contract_needed, and ', ...
             'air_static_placeholder_contract_needed.']);
    end
    if ~isstruct(medium_spec) || ~isscalar(medium_spec)
        error('CerUPP:InvalidMediumSpec', ...
            'resolve_driver_controls requires an explicit scalar struct medium_spec.');
    end
    if isempty(me) || ~isscalar(me) || ~isnumeric(me) || ~isreal(me) || ~isfinite(me) || (double(me) <= 0)
        error('CerUPP:InvalidElectronMass', ...
            'resolve_driver_controls requires me as a finite real scalar > 0 [kg].');
    end
    if ~isstruct(run_warn_state) || ~isscalar(run_warn_state)
        error('CerUPP:InvalidRunWarnState', ...
            'resolve_driver_controls requires an explicit scalar struct run_warn_state.');
    end
    if ~isstruct(setup_physics_rewrite_report) || ~isscalar(setup_physics_rewrite_report)
        error('CerUPP:InvalidSetupPhysicsRewriteReport', ...
            'resolve_driver_controls requires an explicit scalar struct setup_physics_rewrite_report.');
    end
    if ~isa(record_setup_physics_rewrite_fn, 'function_handle')
        error('CerUPP:MissingSetupPhysicsRewriteRecorder', ...
            'resolve_driver_controls requires record_setup_physics_rewrite_fn as a function handle.');
    end
    if ~isa(init_setup_physics_rewrite_report_fn, 'function_handle')
        error('CerUPP:MissingSetupPhysicsRewriteReportInit', ...
            'resolve_driver_controls requires init_setup_physics_rewrite_report_fn as a function handle.');
    end
    if isempty(keldysh_enabled_requested)
        error('CerUPP:MissingKeldyshEnabledFlag', ...
            'resolve_driver_controls requires an explicit keldysh_enabled_requested value.');
    end
    if isempty(keldysh_lookup_csv_name_requested)
        error('CerUPP:MissingKeldyshLookupCsvName', ...
            'resolve_driver_controls requires an explicit keldysh_lookup_csv_name_requested value.');
    end
    air_dynamic_keldysh_contract_needed = logical( ...
        struct_utils.normalize_bool_scalar( ...
            air_dynamic_keldysh_contract_needed, ...
            'air_dynamic_keldysh_contract_needed', ...
            'CerUPP:InvalidAirDynamicKeldyshContractGate'));
    air_static_placeholder_contract_needed = logical( ...
        struct_utils.normalize_bool_scalar( ...
            air_static_placeholder_contract_needed, ...
            'air_static_placeholder_contract_needed', ...
            'CerUPP:InvalidAirStaticPlaceholderContractGate'));
    % Keep the full callback pair explicit at the public contract even
    % though this policy gate only uses the recorder.

    keldysh_enabled_requested = struct_utils.normalize_bool_scalar( ...
        keldysh_enabled_requested, 'keldysh_enabled', 'CerUPP:InvalidKeldyshEnabledFlag');
    if ~isempty(keldysh_display_k_requested)
        if ~(isscalar(keldysh_display_k_requested) && isnumeric(keldysh_display_k_requested) && ...
                isreal(keldysh_display_k_requested) && isfinite(double(keldysh_display_k_requested)) && ...
                (double(keldysh_display_k_requested) > 0))
            error('CerUPP:InvalidKeldyshDisplayK', ...
                'keldysh_display_k must be [] or a finite real scalar > 0.');
        end
        keldysh_display_k_requested = double(keldysh_display_k_requested);
    end
    if isstring(keldysh_lookup_csv_name_requested) && isscalar(keldysh_lookup_csv_name_requested)
        keldysh_lookup_csv_name_requested = char(keldysh_lookup_csv_name_requested);
    end
    if ~ischar(keldysh_lookup_csv_name_requested)
        error('CerUPP:InvalidKeldyshLookupCsvName', ...
            'keldysh_lookup_csv_name_requested must be a nonempty char/string file name.');
    end
    keldysh_lookup_csv_name_requested = strtrim(keldysh_lookup_csv_name_requested);
    if isempty(keldysh_lookup_csv_name_requested)
        error('CerUPP:InvalidKeldyshLookupCsvName', ...
            'keldysh_lookup_csv_name_requested must be a nonempty char/string file name.');
    end
    medium_kind = plasma_keldysh_medium_kind_from_spec_local(medium_spec);
    keldysh_ctrl = struct( ...
        'keldysh_enabled', keldysh_enabled_requested, ...
        'keldysh_display_k_requested', keldysh_display_k_requested, ...
        'keldysh_display_k_effective', keldysh_display_k_requested, ...
        'keldysh_display_k_source', 'auto_reference_threshold', ...
        'keldysh_reference_k_mode', 'discrete_threshold', ...
        'keldysh_convention_autoselect_used', logical(struct_utils.opt_struct_field( ...
            medium_spec, 'keldysh_convention_autoselect_used', false)), ...
        'use_solid_state_keldysh_flag', strcmpi(medium_kind, 'solid'), ...
        'medium_kind', medium_kind, ...
        'resolved_keldysh_convention_desc', 'placeholder_no_live_interband_keldysh', ...
        'keldysh_mred_over_me', 1.0, ...
        'keldysh_mred_kg', NaN, ...
        'plasma_m_over_me', double(struct_utils.opt_struct_field( ...
            medium_spec, 'plasma_m_over_me', NaN)), ...
        'm_plasma_kg', NaN, ...
        'keldysh_lookup_csv_name', keldysh_lookup_csv_name_requested, ...
        'keldysh_keff_bookkeeping_mode', 'display_k');
    if strcmpi(medium_kind, 'solid')
        keldysh_ctrl.resolved_keldysh_convention_desc = 'solid_interband_gamma_prefactor';
        keldysh_ctrl.keldysh_mred_over_me = double(struct_utils.opt_struct_field( ...
            medium_spec, 'keldysh_mred_over_me_solid', NaN));
    end
    % These medium defaults arrive as mass ratios relative to me. Use me
    % only to recover the SI masses here, while keeping the Keldysh
    % reduced mass and the separate Drude plasma mass distinct.

    keldysh_ctrl.keldysh_mred_kg = keldysh_ctrl.keldysh_mred_over_me * me;
    keldysh_ctrl.m_plasma_kg = keldysh_ctrl.plasma_m_over_me * me;
    if ~isscalar(keldysh_ctrl.m_plasma_kg) || ~isfinite(keldysh_ctrl.m_plasma_kg) || ...
            ~isreal(keldysh_ctrl.m_plasma_kg) || (keldysh_ctrl.m_plasma_kg <= 0)
        error('CerUPP:InvalidPlasmaEffectiveMass', ...
            'm_plasma_kg must be a finite real scalar > 0 [kg]; got %s.', ...
            mat2str(keldysh_ctrl.m_plasma_kg));
    end
    if air_dynamic_keldysh_contract_needed && ...
            logical(keldysh_ctrl.keldysh_enabled) && ...
            strcmpi(char(string(struct_utils.opt_struct_field( ...
            medium_spec, 'name', ''))), 'AIR')
        error('CerUPP:AirKeldyshInterbandRateUnsupported', ...
            ['medium.name=Air selects the built-in Air placeholder fallback, ', ...
             'which does not expose a supported gas-model dynamic Keldysh OFI path here. ', ...
             'Disable dynamic Keldysh or use a supported non-placeholder medium.']);
    end
    if ~isempty(keldysh_display_k_requested) && ~logical(keldysh_ctrl.keldysh_enabled)
        [run_warn_state, setup_physics_rewrite_report] = ...
            plasma_keldysh_record_setup_rewrite_local( ...
            record_setup_physics_rewrite_fn, ...
            run_warn_state, setup_physics_rewrite_report, ...
            'keldysh_display_k_disabled', ...
            'setup_keldysh_display_k_disabled', ...
            'CerUPP:KeldyshDisplayKRequiresDynamicKeldysh', ...
            true, false, ...
            ['A nonempty keldysh_display_k requires a live dynamic Keldysh OFI branch. ', ...
             'Ignoring the requested display/diagnostic exponent because the dynamic W(I) branch is inactive.']);
        keldysh_ctrl.keldysh_display_k_effective = [];
        keldysh_ctrl.keldysh_display_k_source = 'disabled_without_dynamic_keldysh';
    end
    if air_static_placeholder_contract_needed && ...
            ~logical(keldysh_ctrl.keldysh_enabled) && ...
            strcmpi(char(string(struct_utils.opt_struct_field( ...
            medium_spec, 'name', ''))), 'AIR')
        sigma_abs_max = 0.0;
        if ~isempty(sigma_k_vec)
            sigma_abs_max = max(abs(double(sigma_k_vec(:))));
        end
        if sigma_abs_max <= 0
            error('CerUPP:AirStaticOFICoefficientsRequired', ...
                ['medium.name=Air with keldysh_enabled=false requires explicit nonzero gas MPI coefficients in sigma_k_vec. ', ...
                 'Zero sigma_k_vec disables the only supported built-in Air OFI path here. ', ...
                 'Set medium_cfg.sigma_k_vec and medium_cfg.k_power_vec in the canonical medium_cfg path ', ...
                 'to enable static MPI OFI.']);
        end
    end
end

function medium_kind = plasma_keldysh_medium_kind_from_spec_local(medium_spec)
% Classify the built-in medium family from the canonical medium name.

    if nargin < 1 || ~isstruct(medium_spec) || ~isscalar(medium_spec)
        error('CerUPP:InvalidMediumSpec', ...
            'medium_kind_from_spec requires an explicit scalar struct medium_spec.');
    end
    if ~isfield(medium_spec, 'name') || isempty(medium_spec.name)
        error('CerUPP:InvalidMediumSpec', ...
            'medium_kind_from_spec requires medium_spec.name.');
    end
    medium_name = upper(strtrim(char(string(medium_spec.name))));
    switch medium_name
        case 'YAG'
            medium_kind = 'solid';
        case 'AIR'
            medium_kind = 'gas';
        otherwise
            medium_kind = '';
    end
end

function requested_name = plasma_keldysh_requested_ofi_model_name_from_spec_local(medium_spec)
% Return the built-in OFI-family label implied by the canonical medium.

    if nargin < 1 || ~isstruct(medium_spec) || ~isscalar(medium_spec)
        error('CerUPP:InvalidMediumSpec', ...
            'requested_ofi_model_name_from_spec requires an explicit scalar struct medium_spec.');
    end
    if ~isfield(medium_spec, 'name') || isempty(medium_spec.name)
        error('CerUPP:InvalidMediumSpec', ...
            'requested_ofi_model_name_from_spec requires medium_spec.name.');
    end
    medium_name = upper(strtrim(char(string(medium_spec.name))));
    switch medium_name
        case 'YAG'
            requested_name = 'solid_interband_keldysh_rate';
        case 'AIR'
            requested_name = 'air_static_placeholder_family';
        otherwise
            requested_name = '';
    end
end

function medium_spec = plasma_keldysh_attach_ofi_model_policy_labels_local( ...
        medium_spec, keldysh_enabled, k_power_vec_2, sigma_k_vec, plasma_flag, ion_routine_flag)
% Tag medium_spec with the requested built-in OFI family and active closure family.

    if nargin < 6
        error('CerUPP:MissingOfiPolicyInputs', ...
            ['attach_ofi_model_policy_labels requires medium_spec, keldysh_enabled, ', ...
             'k_power_vec_2, sigma_k_vec, plasma_flag, and ion_routine_flag.']);
    end
    if ~isstruct(medium_spec) || ~isscalar(medium_spec)
        error('CerUPP:InvalidMediumSpec', ...
            'attach_ofi_model_policy_labels requires an explicit scalar struct medium_spec.');
    end
    if isempty(keldysh_enabled)
        error('CerUPP:MissingKeldyshEnabledFlag', ...
            'attach_ofi_model_policy_labels requires an explicit keldysh_enabled value.');
    end
    if isempty(plasma_flag)
        error('CerUPP:MissingPlasmaFlag', ...
            'attach_ofi_model_policy_labels requires an explicit plasma_flag value.');
    end
    if isempty(ion_routine_flag) || ~isscalar(ion_routine_flag) || ~isnumeric(ion_routine_flag) || ...
            ~isreal(ion_routine_flag) || ~isfinite(double(ion_routine_flag))
        error('CerUPP:InvalidIonRoutineFlag', ...
            'attach_ofi_model_policy_labels requires ion_routine_flag as a finite real scalar.');
    end
    keldysh_enabled = struct_utils.normalize_bool_scalar( ...
        keldysh_enabled, 'keldysh_enabled', 'CerUPP:InvalidKeldyshEnabledFlag');
    plasma_flag = struct_utils.normalize_bool_scalar( ...
        plasma_flag, 'plasma_flag', 'CerUPP:InvalidPlasmaFlag');
    medium_name = upper(strtrim(char(string(struct_utils.opt_struct_field(medium_spec, 'name', '')))));
    medium_kind = lower(strtrim(plasma_keldysh_medium_kind_from_spec_local(medium_spec)));
    ofi_branch_active = plasma_keldysh_is_ofi_branch_active_local(plasma_flag, ion_routine_flag);
    requested_name = char(plasma_keldysh_requested_ofi_model_name_from_spec_local(medium_spec));
    family_name = requested_name;
    if isempty(strtrim(family_name))
        if strcmp(medium_name, 'AIR')
            family_name = 'air_static_placeholder_family';
        elseif strcmp(medium_kind, 'solid') || strcmp(medium_name, 'YAG')
            family_name = 'solid_interband_keldysh_rate';
        else
            family_name = 'static_mpi_powerlaw';
        end
    end

    active_name = 'disabled';
    if ofi_branch_active
        sigma_abs_max = 0.0;
        if nargin >= 4 && ~isempty(sigma_k_vec)
            sigma_abs_max = max(abs(double(sigma_k_vec(:))));
        end
        if logical(keldysh_enabled)
            if strcmp(medium_name, 'AIR')
                active_name = 'air_static_mpi_placeholder';
            elseif strcmp(medium_kind, 'solid') || strcmp(medium_name, 'YAG')
                active_name = 'solid_interband_keldysh_dynamic_W';
            else
                active_name = 'keldysh_dynamic_W';
            end
        elseif strcmp(medium_name, 'AIR')
            active_name = 'air_static_mpi_placeholder';
        elseif nargin >= 3 && ~isempty(k_power_vec_2) && (sigma_abs_max > 0)
            active_name = 'static_mpi_powerlaw';
        end
    end

    medium_spec.ofi_model_family = family_name;
    medium_spec.ofi_model_active = active_name;
end

function ofi_branch_active = plasma_keldysh_is_ofi_branch_active_local(plasma_flag, ion_routine_flag)
% Tell setup whether the OFI source branch is physically active this run.

    ofi_branch_active = false;
    if ~(isscalar(plasma_flag) && (islogical(plasma_flag) || isnumeric(plasma_flag)))
        return;
    end
    if ~logical(plasma_flag)
        return;
    end
    if ~(isscalar(ion_routine_flag) && isnumeric(ion_routine_flag) && isreal(ion_routine_flag) && ...
            isfinite(double(ion_routine_flag)))
        return;
    end
    ofi_branch_active = ismember(double(ion_routine_flag), [1 2]);
end

function [kcfg, run_warn_state] = plasma_keldysh_build_runtime_cfg_disabled_from_setup_local( ...
        setup, run_warn_state)
% Build the disabled runtime shell when dynamic Keldysh OFI is off.
% This keeps the accounting fields well-shaped for downstream code while
% making it explicit that no active W(I) table was built.

    run_warn_state = struct_utils.ensure_warned_keys_map(run_warn_state);
    use_solid_state_keldysh_flag = logical(setup.use_solid_state_keldysh_flag);
    policy = plasma_keldysh_setup.resolve_policy(struct());
    runtime_model = plasma_setup_support.build_keldysh_runtime_model_local( ...
        setup, policy, use_solid_state_keldysh_flag);
    if setup.keldysh_enabled && ~setup.keldysh_runtime_enabled
        lookup_cache_identity = 'inactive_compact_disabled';
    else
        lookup_cache_identity = 'disabled_not_requested';
    end
    kcfg = plasma_setup_support.build_keldysh_runtime_cfg_shell_local( ...
        runtime_model);
    kcfg.scalar_lookup_mode = 'inactive';
    kcfg.lookup_cache_identity = lookup_cache_identity;
    rho_nt_scalar = double(real(setup.rho_nt_m3));
    if isscalar(rho_nt_scalar) && isfinite(rho_nt_scalar) && (rho_nt_scalar > 0)
        kcfg.rho_nt_m3 = rho_nt_scalar;
    end
    rho_nt_norm_scalar = double(real(setup.rho_nt_keldysh_norm_m3));
    if ~(isscalar(rho_nt_norm_scalar) && isfinite(rho_nt_norm_scalar) && (rho_nt_norm_scalar > 0))
        rho_nt_norm_scalar = rho_nt_scalar;
    end
    if isscalar(rho_nt_norm_scalar) && isfinite(rho_nt_norm_scalar) && (rho_nt_norm_scalar > 0)
        kcfg.rho_nt_keldysh_norm_m3 = rho_nt_norm_scalar;
    end
end

function [run_warn_state, setup_physics_rewrite_report] = plasma_keldysh_record_setup_rewrite_local( ...
        record_setup_physics_rewrite_fn, run_warn_state, setup_physics_rewrite_report, ...
        rewrite_key, phase_tag, warn_id, requested_value, effective_value, detail_msg)
% Record one requested->effective physics rewrite through the driver callback.

    if nargin < 1 || ~isa(record_setup_physics_rewrite_fn, 'function_handle')
        error('plasma_keldysh_setup:MissingSetupRewriteRecorder', ...
            'resolve_driver_controls requires a record_setup_physics_rewrite callback.');
    end
    [run_warn_state, setup_physics_rewrite_report] = record_setup_physics_rewrite_fn( ...
        run_warn_state, setup_physics_rewrite_report, ...
        rewrite_key, phase_tag, warn_id, requested_value, effective_value, detail_msg);
end

function [kcfg, run_warn_state] = plasma_keldysh_build_runtime_cfg_active_from_setup_local(setup, run_warn_state)
% Active runtime builder for the dynamic Keldysh OFI branch.
% Main setup-math path:
% - validate the active solid-state convention
% - choose one provisional scalar K reference for the setup-time lookup work
% - build the W(I) lookup table and interpolation objects
% - attach the resulting diagnostic/interpolation curves to kcfg

    run_warn_state = struct_utils.ensure_warned_keys_map(run_warn_state);
    if logical(setup.keldysh_runtime_enabled)
        plasma_setup_support.require_supported_solid_keldysh_convention_local( ...
            setup.use_solid_state_keldysh_flag, 'build_runtime_cfg');
    end
    keldysh_gamma_convention = plasma_setup_support.describe_keldysh_gamma_convention_local( ...
        setup.use_solid_state_keldysh_flag);

    [run_output_root, keldysh_lookup_csv_name, lookup_cache_policy_cfg] = ...
        plasma_setup_support.validate_keldysh_runtime_artifact_inputs_local(setup);
    policy = plasma_keldysh_setup.resolve_policy(struct());
    runtime_model = plasma_setup_support.build_keldysh_runtime_model_local( ...
        setup, policy, logical(setup.use_solid_state_keldysh_flag));
    kcfg = plasma_setup_support.build_keldysh_runtime_cfg_shell_local( ...
        runtime_model);
    kcfg.hbar_omega_J = double(setup.hbar) * double(setup.omega_fund);
    kcfg.gamma_convention = char(keldysh_gamma_convention);
    kcfg.scalar_lookup_mode = 'lut_loglinear_fundamental';
    kcfg.lookup_cache_identity = 'runtime_rebuilt_standard_gamma';
    kcfg.lookup_source_mode = 'pending_runtime_build';
    kcfg.lookup_artifact_path = '';
    kcfg.lookup_cache_key_tag = '';
    kcfg.lookup_reused_without_metadata_match = false;
    kcfg.lookup_cache_metadata_check_skipped = logical( ...
        lookup_cache_policy_cfg.allow_without_metadata_match);
    kcfg.lookup_cache_policy = char(lookup_cache_policy_cfg.policy_name);
    kcfg.lookup_cache_dev_override_active = logical( ...
        lookup_cache_policy_cfg.allow_without_metadata_match);
    kcfg.lookup_cache_dev_override_reason = '';
    if kcfg.lookup_cache_metadata_check_skipped
        kcfg.lookup_cache_metadata_policy = char(lookup_cache_policy_cfg.policy_name);
        run_warn_state = run_warn_state_utils.emit_warn_once_with_phase( ...
            run_warn_state, char(setup.phase_tag), ...
            'keldysh_lookup_cache_metadata_check_skipped', ...
            'CerUPP:KeldyshLookupCacheMetadataCheckSkipped', ...
            ['Relaxed Keldysh LUT cache reuse is active for this run. ', ...
             'CerUPP may load an existing Keldysh LUT cache without requiring the expected ', ...
             'physics metadata match, so the cached W(I) law may come from a different setup.']);
    else
        kcfg.lookup_cache_metadata_policy = 'require_expected_cache_metadata_match';
    end

    rho_nt_scalar = double(real(setup.rho_nt_m3));
    if ~isscalar(rho_nt_scalar) || ~isfinite(rho_nt_scalar) || (rho_nt_scalar <= 0)
        error('plasma_keldysh_setup:InvalidRhoNt', ...
            'rho_nt_m3 must be a finite real scalar > 0 for Keldysh setup; got %s.', ...
            mat2str(setup.rho_nt_m3));
    end
    kcfg.rho_nt_m3 = rho_nt_scalar;
    rho_nt_norm_scalar = double(real(setup.rho_nt_keldysh_norm_m3));
    if ~isscalar(rho_nt_norm_scalar) || ~isfinite(rho_nt_norm_scalar) || (rho_nt_norm_scalar <= 0)
        rho_nt_norm_scalar = rho_nt_scalar;
    end
    kcfg.rho_nt_keldysh_norm_m3 = rho_nt_norm_scalar;

    % Choose the setup-time scalar diagnostic exponent before the LUT is built.
    % Dynamic Keldysh OFI still propagates with the same sampled W(I) curve;
    % this scalar K only translates W(I) into sigma_K,eff and beta_eff_*.
    % The default auto rule evaluates the effective gap at the setup
    % reference intensity I_ref = keldysh_lut_i_roi_min, forms
    %   nu_cont = Eg_eff(I_ref)/(hbar * omega_fund) + 1,
    % then applies the same tolerance-stabilized threshold rule used by
    % the solid-state rate:
    %   nu_int = max(floor(nu_cont + nu_tol), 1),
    %   K_display = nu_int.
    [k_display_auto, bookkeeping_reference_info, kcfg.soft_warn_state] = ...
        plasma_keldysh_setup.compute_keldysh_bookkeeping_reference_k( ...
        setup.keldysh_lut_i_roi_min, setup.omega_fund, setup.keldysh_gap_j, setup.keldysh_mred_kg, ...
        setup.n_sell_fund, setup.ep0, setup.c, setup.qe, setup.hbar, ...
        setup.use_solid_state_keldysh_flag, policy.keldysh_reference_k_mode, kcfg.soft_warn_state);
    if ~(isfinite(k_display_auto) && (k_display_auto > 0))
        error('plasma_keldysh_setup:KeldyshDisplayKInvalid', ...
            'Automatic Keldysh display/diagnostic exponent computation returned invalid K=%s.', mat2str(k_display_auto));
    end
    k_display_selected = double(k_display_auto);
    has_user_display_override = isfield(setup, 'keldysh_display_k') && ...
        ~isempty(setup.keldysh_display_k);
    k_display_source = 'auto_reference_threshold';
    if has_user_display_override
        k_display_selected = double(setup.keldysh_display_k);
        k_display_source = 'user_override';
    end
    if ~(isfinite(k_display_selected) && (k_display_selected > 0))
        error('plasma_keldysh_setup:InvalidSelectedDisplayK', ...
            'Selected Keldysh display/diagnostic exponent must be finite and > 0.');
    end
    kcfg.K_override_val = double(k_display_selected);
    kcfg.K_override_gap_ratio = double(bookkeeping_reference_info.gap_ratio);
    kcfg.K_override_threshold_order = double(bookkeeping_reference_info.threshold_order);
    kcfg.K_override_nu_cont = double(bookkeeping_reference_info.nu_cont);
    kcfg.K_override_nu_int = double(bookkeeping_reference_info.nu_int);
    kcfg.K_override_reference_intensity_wm2 = double( ...
        bookkeeping_reference_info.reference_intensity_wm2);
    kcfg.K_display = double(k_display_selected);
    kcfg.K_display_source = char(k_display_source);
    kcfg.K_display_auto = double(k_display_auto);
    kcfg.K_display_gap_ratio = double(bookkeeping_reference_info.gap_ratio);
    kcfg.K_display_threshold_order = double(bookkeeping_reference_info.threshold_order);
    kcfg.K_display_nu_cont = double(bookkeeping_reference_info.nu_cont);
    kcfg.K_display_nu_int = double(bookkeeping_reference_info.nu_int);
    kcfg.K_display_reference_intensity_wm2 = double( ...
        bookkeeping_reference_info.reference_intensity_wm2);
    kcfg.K_eff_single = double(k_display_selected);
    kcfg.K_eff_single_bookkeeping = double(k_display_selected);
    kcfg.keldysh_effective_diag_enabled = true;
    kcfg.keldysh_effective_diag_status = 'ready';
    try
        [kcfg, run_warn_state] = plasma_keldysh_finish_runtime_cfg_local( ...
            kcfg, run_warn_state, setup.phase_tag, ...
            keldysh_lookup_csv_name, setup.keldysh_lut_i_roi_min, ...
            setup.ep0, setup.c, setup.qe, setup.hbar, run_output_root, ...
            kcfg.lookup_cache_metadata_check_skipped, ...
            setup.plot_policy, setup.k_power_vec, setup.sigma_k_vec);
    catch me_2
        error('plasma_keldysh_setup:KeldyshSetupHardFail', ...
            ['Keldysh enabled requires successful runtime interpolation setup; ', ...
             'no static-fallback mode is allowed. Root cause: %s'], me_2.message);
    end
end

function k_eff_single = resolve_scalar_bookkeeping_keff_single_local(i_seed_wm2, k_power_vec_2, sigma_k_vec)
% Resolve one scalar display/diagnostic exponent K_eff_single from the user MPI order family.
% This does not change the dynamic W(I) law used by Keldysh OFI. It only
% supplies one scalar exponent for exported K_eff/sigma_K,eff/beta_K,eff
% diagnostics and for the matched-Keldysh accounting view.
%
% Cases:
% - one active term  -> keep that K directly
% - multiple terms   -> use the ROI-seed weighted mean
%       w_k = sigma_k * I_seed^K_k
%       K_eff = sum(w_k K_k) / sum(w_k)
% The weighting is done in log space for numerical stability.

    [k_user_row, sigma_user_row, valid_k_mask_row, active_mask_row] = ...
        normalize_keldysh_bookkeeping_terms_local(k_power_vec_2, sigma_k_vec);
    k_user = k_user_row(:);
    sigma_user = sigma_user_row(:);
    valid_k = valid_k_mask_row(:);
    active_mask = active_mask_row(:);
    if ~any(valid_k)
        error('plasma_keldysh_setup:KeldyshInvalidK', ...
            ['Keldysh accounting requires K_power_vec to provide at least one finite positive reference order. ', ...
             'The dynamic W(I) evaluator remains separate from this accounting scalar.']);
    end
    if nnz(active_mask) <= 1
        if any(active_mask)
            k_eff_single = double(k_user(find(active_mask, 1, 'first')));
        else
            k_eff_single = double(k_user(find(valid_k, 1, 'first')));
        end
        return;
    end
    if ~(isscalar(i_seed_wm2) && isnumeric(i_seed_wm2) && isreal(i_seed_wm2) && isfinite(i_seed_wm2) && (i_seed_wm2 > 0))
        error('plasma_keldysh_setup:InvalidKeldyshRoiMinIntensity', ...
            ['keldysh_lut_i_roi_min must be a finite real scalar > 0 when resolving ', ...
             'multi-K K_eff_single from the active accounting reference set; got %s.'], ...
            mat2str(i_seed_wm2));
    end
    k_active = k_user(active_mask);
    sigma_active = sigma_user(active_mask);
    i_seed = double(i_seed_wm2);
    log_i = log(max(i_seed, realmin('double')));
    log_sigma = log(sigma_active);
    term = log_sigma + (log_i .* k_active);
    max_log = max(term);
    weights = exp(term - max_log);
    denom = sum(weights);
    numer = sum(weights .* k_active);
    if ~isfinite(denom) || (denom <= 0) || ~isfinite(numer)
        error('plasma_keldysh_setup:InvalidKeldyshMultiKWeights', ...
            'Failed to resolve multi-K K_eff_single from the active (K,sigma_K) set at the ROI seed intensity.');
    end
    k_eff_single = numer ./ denom;
    if ~(isfinite(k_eff_single) && (k_eff_single > 0))
        error('plasma_keldysh_setup:InvalidKeldyshEffectiveK', ...
            'Resolved multi-K K_eff_single is non-finite or nonpositive.');
    end
end

function [k_user, sigma_user, valid_k_mask, active_mask] = normalize_keldysh_bookkeeping_terms_local(k_power_vec, sigma_k_vec)
% Normalize accounting vectors for one consistent active-term definition.
% An accounting term is:
% - valid if K is finite and positive
% - active if K is valid and sigma_K is finite and positive
% Negative sigma_K values are clipped to zero here so later setup logic can
% reason in terms of active-vs-pruned terms without duplicating that rule.

    k_user = double(k_power_vec(:)).';
    sigma_user = max(double(sigma_k_vec(:)).', 0);
    valid_k_mask = isfinite(k_user) & (k_user > 0);
    if numel(k_user) ~= numel(sigma_user)
        active_mask = false(size(valid_k_mask));
        return;
    end
    active_mask = valid_k_mask & isfinite(sigma_user) & (sigma_user > 0);
end

function [diag_enabled, diag_status, k_user, sigma_user, valid_k_mask, active_mask] = ...
        resolve_keldysh_effective_diag_terms_local(k_power_vec, sigma_k_vec)
% Tell setup whether the optional sigmaK_eff/beta_eff_full/beta_eff_applied family exists.
% This is a small availability test only; it does not choose the actual
% scalar K_eff value.

    [k_user, sigma_user, valid_k_mask, active_mask] = ...
        normalize_keldysh_bookkeeping_terms_local(k_power_vec, sigma_k_vec);
    diag_enabled = false;
    diag_status = 'disabled_missing_bookkeeping_reference';
    if isempty(k_user) || isempty(sigma_user) || (numel(k_user) ~= numel(sigma_user))
        return;
    end
    if ~any(valid_k_mask)
        return;
    end
    if ~any(active_mask)
        diag_status = 'disabled_inactive_bookkeeping_weights';
        return;
    end
    diag_enabled = true;
    diag_status = 'ready';
end

function run_warn_state = plasma_keldysh_emit_phase_warning_local( ...
        run_warn_state, phase_tag, warn_key, canon_id, msg_fmt, varargin)
    if nargin < 2 || isempty(phase_tag)
        error('plasma_keldysh_setup:MissingPhaseTag', ...
            'phase_tag is required for plasma_keldysh_setup phase warnings.');
    end
    run_warn_state = run_warn_state_utils.emit_warn_once_with_phase( ...
        run_warn_state, phase_tag, warn_key, canon_id, msg_fmt, varargin{:});
end

function [kcfg, run_warn_state] = plasma_keldysh_finish_runtime_cfg_local( ...
        kcfg, run_warn_state, phase_tag_for_summary, ...
        keldysh_lookup_csv_name, keldysh_lut_i_roi_min, ...
        ep0, c, qe, hbar, run_output_root, ...
        allow_metadata_mismatch_cache_load, plot_policy_local, ...
        k_power_vec_2, sigma_k_vec)
% Build the scalar W(I) lookup and interpolation objects.
% Grid layout:
% - one coarse global log grid over a user-visible wide intensity band
% - one denser ROI log grid that starts from the chosen ROI lower bound
% The merged grid is then used to evaluate W(I), gamma(I), and the derived
% accounting curves. CerUPP first tries to reuse an existing MAT cache at
% the deterministic path, then falls back to a fresh rebuild when no
% reusable cache is available.

    n_coarse = double(kcfg.lut_n_global);
    n_roi = double(kcfg.lut_n_roi);
    i_coarse_min = double(kcfg.lut_i_global_min_wm2);
    i_coarse_max = double(kcfg.lut_i_global_max_wm2);
    i_roi_max = double(kcfg.lut_i_roi_max_wm2);
    if ~isfinite(n_coarse) || (n_coarse < 2) || (n_coarse ~= floor(n_coarse))
        error('plasma_keldysh_setup:InvalidKeldyshGlobalGridCount', ...
            'keldysh_lut_n_global must be a finite integer >= 2.');
    end
    if ~isfinite(n_roi) || (n_roi < 2) || (n_roi ~= floor(n_roi))
        error('plasma_keldysh_setup:InvalidKeldyshRoiGridCount', ...
            'keldysh_lut_n_roi must be a finite integer >= 2.');
    end
    n_coarse = double(n_coarse);
    n_roi = double(n_roi);
    if ~isfinite(i_coarse_min) || ~(i_coarse_min > 0) || ...
            ~isfinite(i_coarse_max) || ~(i_coarse_max > i_coarse_min) || ...
            ~isfinite(i_roi_max) || ~(i_roi_max > 0)
        error('plasma_keldysh_setup:InvalidKeldyshLutBounds', ...
            ['Keldysh LUT bounds must satisfy 0 < I_global_min < I_global_max and I_roi_max > 0. ', ...
             'Got [%.3e, %.3e] and ROI max %.3e W/m^2.'], ...
            i_coarse_min, i_coarse_max, i_roi_max);
    end
    i_roi_min = double(keldysh_lut_i_roi_min);
    if ~isfinite(i_roi_min) || ~(i_roi_min > 0) || ...
            (i_roi_min < i_coarse_min) || (i_roi_min > i_roi_max)
        error('plasma_keldysh_setup:InvalidKeldyshRoiBounds', ...
            ['Resolved Keldysh LUT ROI lower bound must satisfy ', ...
             'I_global_min <= I_roi_min <= I_roi_max. ', ...
             'Got I_global_min=%.3e, I_roi_min=%.3e, I_roi_max=%.3e W/m^2.'], ...
            i_coarse_min, i_roi_min, i_roi_max);
    end
    kcfg.I_roi_anchor_min = double(i_roi_min);
    kcfg.I_roi_anchor_max = double(i_roi_max);

    lookup_meta = ofi_cache_utils.build_scalar_lookup_cache_meta( ...
        kcfg, n_coarse, n_roi, i_roi_min, i_roi_max, i_coarse_min, i_coarse_max);
    lut_csv = ofi_cache_utils.resolve_keldysh_lookup_csv_path( ...
        run_output_root, keldysh_lookup_csv_name, lookup_meta);
    [lut_dir, lut_stem, ~] = fileparts(lut_csv);
    lut_mat = fullfile(lut_dir, [lut_stem '.mat']);
    [lut_payload, cache_loaded] = ofi_cache_utils.try_load_scalar_lookup_payload( ...
        lut_mat, lookup_meta, allow_metadata_mismatch_cache_load);
    if cache_loaded
        try
            [kcfg, lut_payload] = ofi_cache_utils.apply_scalar_lookup_payload( ...
                kcfg, lut_payload, lut_mat, struct( ...
                    'source_mode', 'reused_cache', ...
                    'reused_without_metadata_match', ...
                        logical(allow_metadata_mismatch_cache_load)));
            [run_warn_state, ~] = ofi_cache_utils.emit_keldysh_setup_artifacts( ...
                kcfg, lut_payload, lut_dir, lut_mat, run_warn_state, ...
                phase_tag_for_summary, run_output_root, plot_policy_local, ...
                n_coarse, n_roi, i_roi_min, i_roi_max, k_power_vec_2, sigma_k_vec);
            return;
        catch
            % Fall through to a fresh rebuild if the existing MAT cache is unreadable or malformed.

        end
    end

    % Combine a broad global sweep with a denser region that starts at the
    % requested ROI lower bound so both low/medium-I structure and the
    % expected working region are sampled well.
    i_lookup = [ ...
        plasma_keldysh_setup.build_log_grid(i_coarse_min, i_coarse_max, n_coarse); ...
        plasma_keldysh_setup.build_log_grid(i_roi_min, i_roi_max, n_roi)];
    i_lookup = unique(i_lookup(:), 'sorted');
    if numel(i_lookup) < 2
        error('plasma_keldysh_setup:KeldyshLookupInsufficientPoints', ...
            'Keldysh enabled requires at least two distinct LUT intensity points.');
    end

    beta_lookup_energy_j = double(struct_utils.opt_struct_field( ...
        kcfg, 'keldysh_matched_depletion_J', struct_utils.opt_struct_field(kcfg, 'Ui_J', NaN)));
    [i_lookup, w_lookup, gamma_lookup, ~, ~, kcfg.soft_warn_state] = ...
        pku_compute_scalar_lookup( ...
        i_lookup, kcfg.omega_fund, kcfg.Eg_J, kcfg.mred_kg, ...
        kcfg.n_fund, ep0, c, qe, hbar, ...
        kcfg.rho_nt_keldysh_norm_m3, beta_lookup_energy_j, ...
        ofi_cache_utils.resolve_scalar_lookup_bookkeeping_order(kcfg), ...
        kcfg.keldysh_use_interference_corrected_rate_flag, ...
        kcfg.use_solid_state_keldysh_flag, ...
        kcfg.soft_warn_state);

    lut_payload = ofi_cache_utils.build_scalar_lookup_payload( ...
        kcfg, lookup_meta, i_lookup, w_lookup, gamma_lookup);
    [kcfg, lut_payload] = ofi_cache_utils.apply_scalar_lookup_payload( ...
        kcfg, lut_payload, lut_mat, struct( ...
            'source_mode', 'fresh_rebuild', ...
            'reused_without_metadata_match', false));
    [run_warn_state, ~] = ofi_cache_utils.emit_keldysh_setup_artifacts( ...
        kcfg, lut_payload, lut_dir, lut_mat, run_warn_state, ...
        phase_tag_for_summary, run_output_root, plot_policy_local, ...
        n_coarse, n_roi, i_roi_min, i_roi_max, k_power_vec_2, sigma_k_vec);
end

function [i_lookup, w_lookup, gamma_lookup, sigma_k_lookup, beta_k_lookup, soft_warn_state] = ...
        pku_compute_scalar_lookup( ...
        i_lookup, omega_eval, eg_lut, mred_lut, n_lut, ep0, c, qe, hbar, ...
        rho_nt_keldysh_norm_m3, ui_j, k_eff_single, ...
        keldysh_use_interference_corrected_rate_flag, ...
        use_solid_state_keldysh_flag, soft_warn_state)
% Evaluate the scalar Keldysh lookup tables on one intensity grid.
% Per sample:
%   I -> E = sqrt(2 I / (n eps0 c))
%   E -> gamma = omega * sqrt(mred * Eg) / (|q| E)
%   gamma -> W via the solid-state interband rate law
% Then convert the volumetric rate to the per-neutral W(I) form used in
% the runtime interpolants, and finally derive accounting-only
% sigma_K,eff / beta_K,eff surfaces from that same W(I) curve.

    if nargin < 15 || isempty(soft_warn_state)
        soft_warn_state = [];
    elseif ~isstruct(soft_warn_state)
        error('plasma_keldysh_setup:InvalidKeldyshSoftWarnState', ...
            'soft_warn_state must be a struct or empty ([]).');
    else
        soft_warn_state = struct_utils.ensure_warned_keys_map(soft_warn_state);
    end
    if nargin < 13 || isempty(keldysh_use_interference_corrected_rate_flag)
        keldysh_use_interference_corrected_rate_flag = false;
    end
    if nargin < 14 || isempty(use_solid_state_keldysh_flag)
        use_solid_state_keldysh_flag = true;
    end
    if ~(isscalar(omega_eval) && isfinite(double(omega_eval)) && (double(omega_eval) > 0))
        error('plasma_keldysh_setup:InvalidKeldyshLookupOmega', ...
            'Scalar Keldysh lookup omega must be finite and positive; got %s.', ...
            mat2str(omega_eval));
    end
    if ~(isscalar(ui_j) && isfinite(double(ui_j)) && (double(ui_j) > 0))
        error('plasma_keldysh_setup:InvalidKeldyshLookupUi', ...
            ['Matched-Keldysh beta_K,eff diagnostic map reconstruction requires a finite positive ', ...
             'depletion-energy scale; got %s.'], mat2str(ui_j));
    end
    i_lookup = double(i_lookup(:));
    [w_lookup, gamma_lookup, soft_warn_state] = ...
        pku_evaluate_scalar_lookup_w_local( ...
        i_lookup, omega_eval, eg_lut, mred_lut, n_lut, ep0, c, qe, hbar, ...
        rho_nt_keldysh_norm_m3, keldysh_use_interference_corrected_rate_flag, ...
        use_solid_state_keldysh_flag, soft_warn_state);
    [i_lookup, w_lookup, gamma_lookup, soft_warn_state] = ...
        pku_refine_isolated_positive_lookup_bins_local( ...
        i_lookup, w_lookup, gamma_lookup, ...
        omega_eval, eg_lut, mred_lut, n_lut, ep0, c, qe, hbar, ...
        rho_nt_keldysh_norm_m3, ...
        keldysh_use_interference_corrected_rate_flag, ...
        use_solid_state_keldysh_flag, soft_warn_state);
    rho_nt_norm_safe = max(double(rho_nt_keldysh_norm_m3), realmin('double'));
    [sigma_k_lookup, beta_k_lookup] = plasma_keldysh_setup.compute_keldysh_sigma_beta_from_w( ...
        w_lookup, i_lookup, k_eff_single, ui_j, rho_nt_norm_safe);
end

function [w_lookup, gamma_lookup, soft_warn_state] = pku_evaluate_scalar_lookup_w_local( ...
        i_lookup, omega_eval, eg_lut, mred_lut, n_lut, ep0, c, qe, hbar, ...
        rho_nt_keldysh_norm_m3, keldysh_use_interference_corrected_rate_flag, ...
        use_solid_state_keldysh_flag, soft_warn_state)
% Evaluate W_ion(I) and gamma(I) on one explicit intensity grid.

    i_lookup = double(i_lookup(:));
    w_lookup = zeros(size(i_lookup));
    gamma_lookup = zeros(size(i_lookup));
    efield_pref = 2.0 / (double(n_lut) * double(ep0) * double(c));
    gamma_pref_const = sqrt(double(mred_lut) * double(eg_lut)) / abs(double(qe));
    gamma_pref = double(omega_eval) * gamma_pref_const;
    rho_nt_norm_safe = max(double(rho_nt_keldysh_norm_m3), realmin('double'));
    lookup_block_size = 256;

    % Build gamma(I) from the in-medium field amplitude
    % E = sqrt(2 I / (n_lut*ep0*c)) implied by the intensity grid, so
    % n_lut enters through this intensity-to-field normalization rather
    % than through a separate solid-rate branch choice, then evaluate W in
    % blocks to keep temporary arrays modest.
    efield_lookup = sqrt(max(efield_pref .* i_lookup, 0.0));
    efield_lookup = max(efield_lookup, realmin('double'));
    gamma_lookup = real(double(gamma_pref ./ efield_lookup));
    for block_start = 1:lookup_block_size:numel(i_lookup)
        block_stop = min(block_start + lookup_block_size - 1, numel(i_lookup));
        block_idx = block_start:block_stop;
        [w_vol, ~, soft_warn_state] = plasma_keldysh_setup.keldysh_solid_interband_rate( ...
            gamma_lookup(block_idx), double(omega_eval), double(eg_lut), double(mred_lut), ...
            hbar, use_solid_state_keldysh_flag, ...
            keldysh_use_interference_corrected_rate_flag, soft_warn_state);

        % Convert the volumetric solid-state rate to the per-neutral
        % W_ion(I) curve used by the runtime interpolation path.
        w_atom = max(real(double(w_vol)) ./ rho_nt_norm_safe, 0.0);
        w_lookup(block_idx) = max(w_atom, 0.0);
    end
end

function [i_lookup, w_lookup, gamma_lookup, soft_warn_state] = ...
        pku_refine_isolated_positive_lookup_bins_local( ...
        i_lookup, w_lookup, gamma_lookup, ...
        omega_eval, eg_lut, mred_lut, n_lut, ep0, c, qe, hbar, ...
        rho_nt_keldysh_norm_m3, ...
        keldysh_use_interference_corrected_rate_flag, ...
        use_solid_state_keldysh_flag, soft_warn_state)
% Retry one under-resolved onset case by inserting a narrow local
% log-intensity stencil around isolated positive W_ion(I) bins once.

    positive_mask = (w_lookup > 0);
    if ~any(positive_mask)
        return;
    end
    positive_seg_start = find(positive_mask & [true; ~positive_mask(1:end-1)]);
    positive_seg_end = find(positive_mask & [~positive_mask(2:end); true]);
    isolated_seg_mask = (positive_seg_end == positive_seg_start);
    if ~any(isolated_seg_mask)
        return;
    end

    isolated_idx = positive_seg_start(isolated_seg_mask);
    local_fracs = [0.2; 0.4; 0.6; 0.8];
    i_refine = [];
    for ii = 1:numel(isolated_idx)
        idx = isolated_idx(ii);
        if idx > 1
            i_refine = [i_refine; ...
                pku_build_local_log_refine_points_local( ...
                i_lookup(idx - 1), i_lookup(idx), local_fracs)];
        end
        if idx < numel(i_lookup)
            i_refine = [i_refine; ...
                pku_build_local_log_refine_points_local( ...
                i_lookup(idx), i_lookup(idx + 1), local_fracs)];
        end
    end
    if isempty(i_refine)
        return;
    end

    i_refine = unique(i_refine(:), 'sorted');
    i_refine = i_refine(~ismember(i_refine, i_lookup));
    if isempty(i_refine)
        return;
    end

    [w_refine, gamma_refine, soft_warn_state] = ...
        pku_evaluate_scalar_lookup_w_local( ...
        i_refine, omega_eval, eg_lut, mred_lut, n_lut, ep0, c, qe, hbar, ...
        rho_nt_keldysh_norm_m3, ...
        keldysh_use_interference_corrected_rate_flag, ...
        use_solid_state_keldysh_flag, soft_warn_state);
    i_lookup = [i_lookup; i_refine];
    w_lookup = [w_lookup; w_refine];
    gamma_lookup = [gamma_lookup; gamma_refine];
    [i_lookup, sort_idx] = sort(i_lookup, 'ascend');
    w_lookup = w_lookup(sort_idx);
    gamma_lookup = gamma_lookup(sort_idx);
    [soft_warn_state, ~] = warning_utils.cerupp_warn_once( ...
        soft_warn_state, ...
        'KELDYSH_ISOLATED_POSITIVE_RATE_BIN_REFINED', ...
        'CerUPP:Keldysh:IsolatedPositiveRateBinRefined', ...
        ['Keldysh W_ion(I) lookup support was under-resolved on the initial intensity grid. ', ...
         'CerUPP inserted %d local log-intensity refinement samples around %d isolated positive ', ...
         'segment(s) and rebuilt that onset once before installing the runtime interpolant.'], ...
        numel(i_refine), numel(isolated_idx));
end

function i_refine = pku_build_local_log_refine_points_local(i_lo, i_hi, frac_vec)
% Return one interior log-space stencil between two distinct intensities.

    if ~(isscalar(i_lo) && isfinite(i_lo) && (i_lo > 0) && ...
            isscalar(i_hi) && isfinite(i_hi) && (i_hi > i_lo))
        i_refine = zeros(0, 1);
        return;
    end
    frac_vec = double(frac_vec(:));
    keep_frac = isfinite(frac_vec) & (frac_vec > 0) & (frac_vec < 1);
    frac_vec = frac_vec(keep_frac);
    if isempty(frac_vec)
        i_refine = zeros(0, 1);
        return;
    end
    log_lo = log(double(i_lo));
    log_hi = log(double(i_hi));
    i_refine = exp((1 - frac_vec) .* log_lo + frac_vec .* log_hi);
end
