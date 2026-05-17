function [lin_index_3d, nl_index_3d, mask_2_d, medium_meta] = Rod_on_Air( ...
        x, y, n_selm, core_radius, lambda_window, n2_kerr, z_curr)
    %========================================================================== 
    % ROD_ON_AIR 
    %========================================================================== 
    % Build a 3D linear-index map n(x,y,omega) and a separate 2D Kerr map
    % n2(x,y) for the default rod-in-air built-in surface.
    % User edit guide:
    % - This helper owns the default rod-in-air transverse optical surface.
    % - For ordinary geometry-only parameter changes, edit the Section-1
    %   knobs in cerupp.m such as core_radius and the active medium inputs.
    % - If you want the rod shape or index medium to vary with z, use
    %   z_curr here and enable the driver-side z_dependent_medium_flag so
    %   the current medium is rebuilt during propagation.
    %
    % CONTRACT / INVARIANTS:
    % - lin_index_3d must be size [nx, ny, nw] and store real n(x,y,omega).
    % - nl_index_3d is a 2D Kerr map [nx, ny] with n2_kerr inside core and 0 outside.
    % - Changes here must preserve shape/units expected by calculate_medium_properties_z
    %   and advance_z_step.
    %
    % DESCRIPTION:
    % This function generates a spatially/spectrally-resolved linear-index
    % map plus a separate spatial Kerr map:
    % - Inside the rod radius (r <= core_radius): the caller-supplied core
    %   refractive-index spectrum n_selm(lambda_window) and Kerr
    %   coefficient n2_kerr.
    % - Outside the rod (r > core_radius): n0 = Sellmeier_Air(lambda_window)
    %   and n2 = 0. Plasma or other air nonlinearities are not set here.
    %   In the current implementation, downstream Kerr/NLA/plasma updates
    %   are core-indexed, so nonlinearity and plasma stay off outside the rod.
    %
    % INPUTS:
    % x, y          : transverse coordinate vectors [m]
    % n_selm        : caller-supplied core refractive-index spectrum
    %                 sampled on lambda_window; must match
    %                 numel(lambda_window)
    % core_radius   : rod radius [m]
    % lambda_window : wavelength grid [m]
    % n2_kerr       : Kerr nonlinear coefficient used inside the rod [m^2/W]
    % z_curr        : optional z location [m]. The default helper
    %                 ignores this and remains z-invariant, but custom
    %                 branches may use it for real z-varying geometry/maps.
    %
    % OUTPUTS:
    % lin_index_3d(x,y,lambda) : linear refractive index n0, dimensionless,
    %    size [numel(x) numel(y) numel(lambda_window)]
    % nl_index_3d(x,y)         : Kerr coefficient n2 [m^2/W], 2D map
    % mask_2_d      : 2D logical mask indicating pixels inside core_radius (r <= core_radius).
    % medium_meta   : helper metadata for this built-in surface builder,
    %                 including z_curr_used and surface_builder_tag.
    %
    %
    % ASSUMPTIONS & LIMITATIONS:
    % - By default this is a rod-in-air step-index cross-section with a
    %   sharp rod/cladding boundary.
    % - By default only the rod carries Kerr nonlinearity; air stays linear here.
    % - For z-dependent geometry or index updates, use z_curr in this file
    %   and enable the driver-side z_dependent_medium_flag so this medium
    %   is rebuilt during propagation.
    % - Strong z-gradients may violate the forward-envelope/paraxial
    %   assumptions and can also drive backscattering or backreflection
    %   that this forward model does not represent.
    %==========================================================================
    % Let callers omit z_curr when they just want the built-in surface.
    if nargin < 7
        z_curr = [];
    end

    % If z_curr is provided, require one real finite scalar z location.
    if ~isempty(z_curr)
        validateattributes(z_curr, {'numeric'}, {'real', 'finite', 'scalar'}, ...
            mfilename, 'z_curr');
    end

    % Start the metadata returned alongside this built-in surface.
    medium_meta = struct( ...
        'z_curr_used', false, ...
        'surface_builder_tag', 'RodOnAirStepIndex');

    % This helper expects x and y as coordinate vectors rather than meshgrids.
    if ~isvector(x) || ~isvector(y)
        error('rod_on_air:InvalidXYVectors', ...
            'x and y must be coordinate vectors [m] (not 2D grids).');
    end

    % Build the rod mask on the x-y grid: points with x^2 + y^2 <=
    % core_radius^2 stay inside the rod.
    x_col = x(:);
    y_row = reshape(y, 1, []);
    core_radius2 = core_radius.^2;
    radius2 = x_col.^2 + y_row.^2;
    mask_2_d = (radius2 <= core_radius2);
    lambda_row = lambda_window(:).';
    n = numel(lambda_row);
    if n < 1
        error('rod_on_air:EmptyLambdaWindow', ...
            'lambda_window must be nonempty.');
    end
    if numel(n_selm) ~= n
        error('rod_on_air:CoreSpectrumLengthMismatch', ...
            ['n_selm length (%d) must match lambda_window length (%d). ', ...
             'Scalar/length-mismatched fallback is disabled to preserve spectral dependence.'], ...
            numel(n_selm), n);
    end

    % Spectral refractive indices (vectorized over lambda)
    n_air_vec = reshape(Sellmeier_Air(lambda_row), 1, 1, n);
    n_yag_vec = reshape(n_selm(:).', 1, 1, n);

    % Background air plus caller-supplied core spectrum (implicit expansion).
    % Both cladding and core are lambda-resolved by construction:
    % n_air_vec = Sellmeier_Air(lambda_window), core spectrum = n_selm(lambda_window).
    lin_index_3d = n_air_vec + mask_2_d .* (n_yag_vec - n_air_vec);

    nl_index_3d = mask_2_d .* n2_kerr;

end
