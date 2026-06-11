function [mask, mask_f, mask_f_w, mask_xy, mask_f_xy] = build_masks( ...
        simple_masks_flag, x, y, r_2, kperp, r_inner, r_outer, ...
        kcut_w, ramp_w, mask_pad_x, mask_pad_y, mask_pad_w, ...
        kperp_nyquist_frac, omega_window, omega_fund)
	% Build the reusable real-space mask, transverse-k Nyquist guard, and spectral guard,
% plus the representative 2-D diagnostic views returned to setup/reporting.
% cerupp.m owns the mask controls and this build call.
% mask_and_offaxis_setup_and_check_validity.m resolves the geometry,
% cutoffs, and setup diagnostics that feed this helper.
% This helper only turns that prepared setup plan into propagation masks
% and representative diagnostic slices.

    if nargin ~= 15
        error('CerUPP:MaskBuild:ArgCount', ...
            'build_masks expects 15 inputs; got %d.', nargin);
    end

    nw = numel(omega_window);
    kcut_w = double(kcut_w(:));
    if isscalar(kcut_w)
        kcut_w = repmat(kcut_w, nw, 1);
    elseif numel(kcut_w) ~= nw
        error('CerUPP:MaskBuild:InvalidKcutVectorLength', ...
            'kcut_w must be scalar or have one entry per omega slice (%d).', nw);
    end
    ramp_w = double(ramp_w(:));
    if isscalar(ramp_w)
        ramp_w = repmat(ramp_w, nw, 1);
    elseif numel(ramp_w) ~= nw
        error('CerUPP:MaskBuild:InvalidRampVectorLength', ...
            'ramp_w must be scalar or have one entry per omega slice (%d).', nw);
    end
    if any(~isfinite(kcut_w)) || any(kcut_w <= 0)
        error('CerUPP:MaskBuild:InvalidKcutVector', ...
            'Every kcut_w entry must be finite and > 0.');
    end
    if any(~isfinite(ramp_w)) || any(ramp_w < 0) || any(ramp_w > kcut_w)
        error('CerUPP:MaskBuild:InvalidRampVector', ...
            'Every ramp_w entry must be finite, >= 0, and <= the matching kcut_w.');
    end
    kperp_nyquist_frac = double(kperp_nyquist_frac);
    if ~isscalar(kperp_nyquist_frac) || ~isfinite(kperp_nyquist_frac) || ...
            (kperp_nyquist_frac <= 0) || (kperp_nyquist_frac > 1)
        error('CerUPP:MaskBuild:InvalidNyquistFraction', ...
            'kperp_nyquist_frac must be a finite scalar in (0, 1].');
    end
    x_vec = double(x(:));
    y_vec = double(y(:));
    if numel(x_vec) < 2 || numel(y_vec) < 2
        error('CerUPP:MaskBuild:InvalidTransverseGrid', ...
            'build_masks requires at least two x points and two y points.');
    end
    dx = x_vec(2) - x_vec(1);
    dy = y_vec(2) - y_vec(1);
    if ~isfinite(dx) || ~isfinite(dy) || (dx <= 0) || (dy <= 0)
        error('CerUPP:MaskBuild:InvalidTransverseGrid', ...
            ['x and y must be finite ascending vectors with positive first spacing; ' ...
             'this helper assumes a uniform grid.']);
    end
    idx_x_ctr = -floor(numel(x_vec) / 2):ceil(numel(x_vec) / 2) - 1;
    idx_y_ctr = -floor(numel(y_vec) / 2):ceil(numel(y_vec) / 2) - 1;
    kx = ifftshift((2 * pi * idx_x_ctr) / (numel(x_vec) * dx));
    ky = ifftshift((2 * pi * idx_y_ctr) / (numel(y_vec) * dy));
    [kx_2, ky_2] = ndgrid(kx, ky);
    k_nyx = max(abs(kx));
    k_nyy = max(abs(ky));
    rect_nyquist_gate = ...
        (abs(kx_2) < (kperp_nyquist_frac * k_nyx)) & ...
        (abs(ky_2) < (kperp_nyquist_frac * k_nyy));
    rect_nyquist_gate = cast(rect_nyquist_gate, 'like', kperp);
    [~, omega_diag_idx] = min(abs(double(omega_window(:)) - double(omega_fund)));

    % Return these 2-D diagnostic views explicitly so setup/reporting can
    % inspect the representative real-space and transverse-k masks. mask_xy
    % is the smooth-mask real-space diagnostic view. mask_f_xy is the
    % build-time nearest sampled spectral slice near omega_fund after the
    % omega-only guard is applied. That slice is diagnostic-only, so it may
    % lose all support even when other omega bins still survive in the full
    % 3-D mask stack. In simple-mask mode the hard radial real-space
    % aperture stays in mask and mask_xy remains empty by design.
    mask_xy = [];
    mask_f_xy = [];

    if ~simple_masks_flag

        % Smooth-mask mode: build a raised-cosine real-space absorber from
        % r_inner to r_outer. The runtime transverse-k mask is the hard
        % rectangular sampled-grid Nyquist gate on every retained frequency
        % slice; kcut_w and ramp_w are validated here because setup/reporting
        % use them as physical review thresholds, not as deletion rules.
        mask_xy = ones(size(r_2));
        idx_ann = (r_2 > r_inner) & (r_2 < r_outer);
        mask_xy(idx_ann) = 0.5 * (1 + cos(pi * (r_2(idx_ann) - r_inner) / (r_outer - r_inner)));
        mask_xy(r_2 >= r_outer) = 0;
        mask = mask_xy;

        mask_f = repmat(rect_nyquist_gate, [1, 1, nw]);

        % The smooth spectral guard starts in centered order so the
        % low/high omega-bin edges can keep the same excluded outer bins as
        % the hard path while adding an interior raised-cosine edge band
        % before shifting back to solver FFT ordering.
        mask_f_w_ctr = ones(1, 1, nw);
        if mask_pad_w > 0
            edge_w = min(mask_pad_w, nw);
            mask_f_w_ctr(1, 1, 1:edge_w) = 0;
            mask_f_w_ctr(1, 1, end-edge_w+1:end) = 0;
            shoulder_w = floor((nw - (2 * edge_w)) / 2);
            shoulder_w = max(min(edge_w, shoulder_w), 0);
            if shoulder_w > 0
                % Exclude the plateau endpoint so even a one-bin edge band
                % stays strictly sub-unity instead of collapsing back to a
                % hard boxcar edge.
                shoulder = 0.5 * (1 - cos(pi * (1:shoulder_w) / (shoulder_w + 1)));
                left_idx = edge_w + (1:shoulder_w);
                right_idx = (nw - edge_w - shoulder_w + 1):(nw - edge_w);
                mask_f_w_ctr(1, 1, left_idx) = shoulder;
                mask_f_w_ctr(1, 1, right_idx) = fliplr(shoulder);
            end
        end
        mask_f_w = ifftshift(mask_f_w_ctr, 3);
        mask_f_xy = mask_f(:, :, omega_diag_idx) .* ...
            cast(mask_f_w(1, 1, omega_diag_idx), 'like', mask_f);
    else

        % Simple-mask mode: keep a hard radial real-space aperture derived
        % from the user edge pads. The runtime transverse-k mask is the same
        % rectangular sampled-grid Nyquist gate used by smooth-mask mode.
        r_hard = min(abs([x(mask_pad_x+1), x(end-mask_pad_x), ...
                          y(mask_pad_y+1), y(end-mask_pad_y)]));
        mask = cast(r_2 <= r_hard, 'like', kperp);
        if ~any(mask(:))
            error('CerUPP:Mask:EmptyRealspacePassband', ...
                ['Simple hard-radial mask has empty real-space passband ', ...
                 '(mask_pad_x=%d, mask_pad_y=%d, num_x_pts=%d, num_y_pts=%d).'], ...
                mask_pad_x, mask_pad_y, numel(x), numel(y));
        end

        mask_f = repmat(rect_nyquist_gate, [1, 1, nw]);

        % As above, build the kept omega interval in centered order first,
        % then shift it into the solver's FFT ordering.
        mask_f_w_ctr = false(1, 1, nw);
        if (2*mask_pad_w) < nw
            mask_f_w_ctr(1, 1, mask_pad_w+1:end-mask_pad_w) = true;
        end
        mask_f_w = ifftshift(mask_f_w_ctr, 3);
        mask_f_xy = mask_f(:, :, omega_diag_idx) .* ...
            cast(mask_f_w(1, 1, omega_diag_idx), 'like', mask_f);
    end

    % Keep the spectral guard as an explicit [1,1,Nw] cube so downstream
    % broadcasting against transverse arrays stays unambiguous.
    if ~isempty(mask_f_w)
        mask_f_w = reshape(mask_f_w, 1, 1, []);
    end
end
