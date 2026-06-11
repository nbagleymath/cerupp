classdef band_diagnostics_utils
%BAND_DIAGNOSTICS_UTILS Shared masked-spectrum band reductions.
% Purpose:
% - Own the generic band-limited intensity/fluence reducers used by
%   storage, restart reassembly, and postprocessing.
% - Keep these shared masked-spectrum utilities separate from the
%   filament-specific onset/notch/width analysis surface.

    methods (Static)
        function band_limited_intensity = compute_band_limited_time_intensity_from_spectrum(masked_spectral_field)
        % Reconstruct masked-band |A|^2 from the supplied spectral field.

            band_limited_time_field = ifft(masked_spectral_field, [], 3);
            band_limited_intensity = real(band_limited_time_field .* conj(band_limited_time_field));
        end

        function fluence_xy = build_weighted_fluence_from_masked_spectrum( ...
                masked_spectral_field, n_ratio_diag_xy, t, delta_t, ...
                fluence_use_parseval, weighted_intensity, parseval_time_grid_ok, ...
                spectral_power_raw, spectral_mask)
        % Build weighted fluence from masked spectra using either the
        % Parseval spectral-power path or the time-domain trapz path.

            if nargin < 6
                weighted_intensity = [];
            end
            if nargin < 7
                parseval_time_grid_ok = [];
            end
            if nargin < 8
                spectral_power_raw = [];
            end
            if nargin < 9
                spectral_mask = [];
            end
            masked_field_ndims = ndims(masked_spectral_field);
            if ~(masked_field_ndims == 3 || masked_field_ndims == 4)
                error('CerUPP:InvalidMaskedSpectrumShape', ...
                    'masked_spectral_field must have ndims 3 or 4; got ndims=%d.', masked_field_ndims);
            end
            nx_local = size(masked_spectral_field, 1);
            ny_local = size(masked_spectral_field, 2);
            nt_local = size(masked_spectral_field, 3);
            n_planes = 1;
            if masked_field_ndims == 4
                n_planes = size(masked_spectral_field, 4);
            end
            if ~isequal(size(n_ratio_diag_xy), [nx_local, ny_local])
                error('CerUPP:InvalidBandDiagWeightShape', ...
                    'n_ratio_diag_xy must have shape [%d %d]; got [%s].', ...
                    nx_local, ny_local, num2str(size(n_ratio_diag_xy)));
            end
            use_parseval_effective = band_diagnostics_utils.resolve_parseval_effective_local( ...
                t, delta_t, fluence_use_parseval, parseval_time_grid_ok);
            if ~isempty(weighted_intensity)
                weighted_ndims = ndims(weighted_intensity);
                if ~(weighted_ndims == 3 || weighted_ndims == 4)
                    error('CerUPP:InvalidWeightedIntensityShape', ...
                        'weighted_intensity must have ndims 3 or 4 for time-domain fluence; got ndims=%d.', ...
                        weighted_ndims);
                end
                if weighted_ndims ~= masked_field_ndims || ~isequal(size(weighted_intensity), size(masked_spectral_field))
                    error('CerUPP:InvalidWeightedIntensityGrid', ...
                        ['weighted_intensity must exactly match masked_spectral_field size %s; ', ...
                         'got %s.'], ...
                        mat2str(size(masked_spectral_field)), mat2str(size(weighted_intensity)));
                end
            end
            if isempty(weighted_intensity) && ~use_parseval_effective
                weighted_intensity = n_ratio_diag_xy .* ...
                    band_diagnostics_utils.compute_band_limited_time_intensity_from_spectrum(masked_spectral_field);
            end
            if use_parseval_effective
                scale_like = real(masked_spectral_field(1));
                if ~isempty(spectral_power_raw)
                    scale_like = real(spectral_power_raw(1));
                end
                scale_parseval = cast(delta_t / nt_local, 'like', scale_like);
                band_power = band_diagnostics_utils.reduce_parseval_band_power_local( ...
                    masked_spectral_field, spectral_power_raw, spectral_mask);
                if masked_field_ndims == 4
                    fluence_xy = reshape(n_ratio_diag_xy, nx_local, ny_local, 1, 1) .* ...
                        scale_parseval .* band_power;
                    fluence_xy = reshape(fluence_xy, nx_local, ny_local, n_planes);
                else
                    fluence_xy = n_ratio_diag_xy .* scale_parseval .* band_power;
                end
            else
                fluence_xy = trapz(t, weighted_intensity, 3);
                if masked_field_ndims == 4
                    fluence_xy = reshape(fluence_xy, nx_local, ny_local, n_planes);
                end
            end
        end

        function fluence_trace = integrate_time_trace_fluence( ...
                intensity_trace, t, delta_t, fluence_use_parseval, ...
                parseval_time_grid_ok, dim)
        % Integrate a stored time trace with the same Parseval-vs-trapz
        % rule used by the stored band-fluence reducers.

            if nargin < 6 || isempty(dim)
                dim = ndims(intensity_trace);
            end
            use_parseval_effective = ...
                band_diagnostics_utils.resolve_parseval_effective_local( ...
                    t, delta_t, fluence_use_parseval, ...
                    parseval_time_grid_ok);
            if use_parseval_effective
                if ~(isscalar(delta_t) && isnumeric(delta_t) && ...
                        isreal(delta_t) && isfinite(delta_t) && ...
                        (double(delta_t) > 0))
                    error('CerUPP:InvalidBandTraceDeltaT', ...
                        'delta_t must be finite and >0 when Parseval fluence integration is active.');
                end
                fluence_trace = delta_t .* sum(intensity_trace, dim);
            else
                fluence_trace = trapz(t, intensity_trace, dim);
            end
        end
    end

    methods (Static, Access = private)
        function use_parseval_effective = resolve_parseval_effective_local( ...
                t, delta_t, fluence_use_parseval, parseval_time_grid_ok)
            use_parseval_effective = false;
            if ~logical(fluence_use_parseval)
                return;
            end
            if nargin >= 4 && ~isempty(parseval_time_grid_ok)
                use_parseval_effective = logical(parseval_time_grid_ok);
                return;
            end
            use_parseval_effective = filament_diagnostics_utils.time_grid_supports_parseval_fluence( ...
                t, delta_t);
        end

        function band_power = reduce_parseval_band_power_local(field_reference, spectral_power_raw, spectral_mask)
            if ~isempty(spectral_power_raw)
                band_power = spectral_power_raw;
                if ~isempty(spectral_mask)
                    band_power = band_power .* spectral_mask;
                end
                band_power = sum(band_power, 3);
                return;
            end
            band_power = sum(real(field_reference .* conj(field_reference)), 3);
        end
    end
end
