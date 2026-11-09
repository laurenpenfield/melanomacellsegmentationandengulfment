%% IGR1 cell segmentation and phalloidin (F-actin) quantification
% Cleaned version of celltrace_phalloidin2.m: same segmentation, but it outputs only
% the phalloidin measurements used for the Prism SuperPlots:
%   Ch4_Mean                   whole-cell mean phalloidin
%   Ch4_Periph_Mean_1um        mean phalloidin in the 1 um band inside the cell edge
%   Ch4_Periph_Interior_Ratio  periphery / interior mean phalloidin, 1.5 um band
% All three are background-subtracted and exclude engulfed-Jurkat pixels.
%
% Input: 4-channel Zeiss ZEN TIFF stacks, page order P1C1, P1C2, P1C3, P1C4, P2C1 ...
%   ch1 = CellTrace (IGR1 cytoplasm), ch2 = far-red Jurkats, ch3 = Hoechst, ch4 = phalloidin
%
% Segmentation
%   1. Jurkats (ch2) are segmented and classed as engulfed (mostly surrounded by
%      CellTrace) or free. Free Jurkats are removed from IGR1 cells; engulfed
%      Jurkats stay in their cell but their pixels are left out of phalloidin values.
%   2. Nuclei (ch3) are segmented and split; each nucleus is one cell seed. Regions
%      without a nucleus that are >= 150 um^2 get a CellTrace seed.
%   3. Cell outline = CellTrace mask OR phalloidin mask (small holes filled; wide dim
%      phalloidin-only regions removed as gaps between cells).
%   4. Touching cells are split by a seeded watershed along the phalloidin cortex.
%   5. Pixels with no CellTrace or phalloidin signal are removed; outer edges are
%      refined to the phalloidin edge (cell-cell borders are not moved).
%   6. Cells < 50 um^2 are removed; cells touching the image border are kept.
% All intensities are measured on the RAW phalloidin image.

%% ================= USER SETTINGS =================
inputDir  = 'data/images';
outputDir = 'data/output_prism';

nChannels = 4;
ch1Idx = 1;  ch2Idx = 2;  ch3Idx = 3;  ch4Idx = 4;   % CellTrace, Jurkats, Hoechst, phalloidin

pixelSizeOverride_um = [];   % [] = read from metadata

% CellTrace (ch1) mask and fallback seeds
gaussianSigma     = 1;       % smoothing (px), all channels, segmentation only
ch1ThreshScale    = 0.7;     % x Otsu
seedH             = 1;       % h-maxima depth (px) for CellTrace fallback seeds
seedFallbackMinArea_um2 = 150;  % nucleus-free regions at least this big get a CellTrace seed

% Phalloidin (ch4) mask
ch4ThreshScale    = 0.8;     % x Otsu
seRadius          = 2;       % closing radius (px)
maxHole_um2       = 20;      % holes up to this size are filled; larger = gaps between cells
maxExtensionWidth_um = 3;    % dim phalloidin-only regions wider than this are removed as gaps
lamellaThreshScale = 1.0;    % phalloidin-only regions brighter than this x Otsu (raw) are kept
minDebris_um2     = 10;      % specks smaller than this are removed

% Jurkats (ch2)
jurkatThreshScale = 1.0;     % x Otsu
jurkatMinArea_um2 = 15;
jurkatMinSNR      = 5;       % robust SDs above the ch2 background
engulfRingFrac    = 0.6;     % engulfed if >= this fraction of a 1 um ring is CellTrace-positive
engulfOverlapFrac = 0.7;     % ...or >= this fraction of the Jurkat overlaps CellTrace
jurkatExclude_px  = 1;       % engulfed-Jurkat mask grown by this before excluding from ch4

% Nuclei (ch3)
nucThreshScale    = 1.0;     % x Otsu
minNucArea_um2    = 15;
nucSplitH         = 2;       % h-maxima depth (px) for splitting touching nuclei

% Watershed, gap removal, edge refinement
ridgeWeight       = 0.85;    % 0.85 x phalloidin + 0.15 x shape
gapThreshScale_ch1 = 0.5;    % pixel must be > this x Otsu in ch1 or ch4 (raw images)
gapThreshScale_ch4 = 0.5;
edgeRefine_um     = 1.5;     % outer edge may move in or out by up to this
edgeHalfMax       = 0.6;     % edge level between background (0) and cortical rim (1)

% Cell filter
minCellArea_um2   = 50;

% Phalloidin measurements
periphWidth_um    = 1;       % band for Ch4_Periph_Mean_1um
ratioWidth_um     = 1.5;     % band for Ch4_Periph_Interior_Ratio
bgExclusion_px    = 10;      % background = median ch4 this far from any cell / Jurkat signal

%% ================= SETUP =================
if ~exist(outputDir, 'dir'), mkdir(outputDir); end
files = dir(fullfile(inputDir, '*.tif'));
cellResults    = table();
summaryResults = table();

%% ================= LOOP OVER FILES =================
for f = 1:numel(files)

    filename = files(f).name;
    fprintf('Processing %s\n', filename);
    imgPath = fullfile(inputDir, filename);
    [~, baseName] = fileparts(filename);

    %% ---- Pixel size ----
    info   = imfinfo(imgPath);
    nPages = numel(info);
    if ~isempty(pixelSizeOverride_um)
        pixelSize_um = pixelSizeOverride_um;
    else
        try
            xRes    = info(1).XResolution;
            resUnit = info(1).ResolutionUnit;
            if (ischar(resUnit) && strcmpi(resUnit, 'Inch')) || isequal(resUnit, 2)
                pixelSize_um = 25400 / xRes;
            elseif (ischar(resUnit) && strcmpi(resUnit, 'Centimeter')) || isequal(resUnit, 3)
                pixelSize_um = 10000 / xRes;
            else
                pixelSize_um = 1 / xRes;
            end
        catch
            pixelSize_um = 1;
            fprintf('  WARNING: Could not read pixel size, using 1 um/px\n');
        end
    end
    fprintf('  Pixel size: %.4f um/px\n', pixelSize_um);

    pixelArea_um2  = pixelSize_um^2;
    minCellArea_px = minCellArea_um2 / pixelArea_um2;
    minDebris_px   = max(1, round(minDebris_um2 / pixelArea_um2));
    maxHole_px     = round(maxHole_um2 / pixelArea_um2);
    extRadius_px   = max(1, round(maxExtensionWidth_um / 2 / pixelSize_um));
    edgeRefine_px  = round(edgeRefine_um / pixelSize_um);
    periph_px      = max(1, round(periphWidth_um / pixelSize_um));
    ratio_px       = max(1, round(ratioWidth_um / pixelSize_um));
    ringWidth_px   = max(2, round(1 / pixelSize_um));     % 1 um ring around each Jurkat
    minNuc_px      = max(1, round(minNucArea_um2 / pixelArea_um2));

    %% ---- Load stack ----
    if mod(nPages, nChannels) ~= 0
        error('Number of pages (%d) is not divisible by nChannels (%d).', nPages, nChannels);
    end
    nPositions = nPages / nChannels;
    samplePage = imread(imgPath, 1);
    [imH, imW] = size(samplePage);
    stack = zeros(imH, imW, nPages, 'like', samplePage);
    for k = 1:nPages
        stack(:,:,k) = imread(imgPath, k);
    end
    img = reshape(stack, imH, imW, nChannels, nPositions);

    for p = 1:nPositions
        fprintf('  Position %d / %d\n', p, nPositions);
        ch1 = double(img(:,:,ch1Idx,p));
        ch2 = double(img(:,:,ch2Idx,p));
        ch3 = double(img(:,:,ch3Idx,p));
        ch4 = double(img(:,:,ch4Idx,p));      % raw, used for all intensity values

        % smoothed raw images (no contrast enhancement) for signal checks
        r1 = imgaussfilt(mat2gray(ch1, double(prctile(ch1(:), [0.5 99.8]))), gaussianSigma);
        r4 = imgaussfilt(mat2gray(ch4, double(prctile(ch4(:), [0.5 99.8]))), gaussianSigma);
        ch4pos    = r4 > gapThreshScale_ch4 * graythresh(r4);
        ch4bright = r4 > lamellaThreshScale * graythresh(r4);

        %% ---- CellTrace mask ----
        ch1_proc = imgaussfilt(adapthisteq(mat2gray(ch1)), gaussianSigma);
        bw1 = ch1_proc > ch1ThreshScale * graythresh(ch1_proc);
        bw1 = imclose(bw1, strel('disk', seRadius));

        %% ---- Jurkats ----
        ch2_proc = imgaussfilt(mat2gray(ch2, double(prctile(ch2(:), [0.5 99.8]))), gaussianSigma);
        J = ch2_proc > jurkatThreshScale * graythresh(ch2_proc);
        ch2s   = imgaussfilt(ch2, gaussianSigma);
        ch2med = median(ch2s(:));
        ch2mad = median(abs(ch2s(:) - ch2med));
        J = J & ch2s > ch2med + jurkatMinSNR * 1.4826 * ch2mad;
        J = imfill(imopen(J, strel('disk', 1)), 'holes');
        J = bwareaopen(J, max(1, round(jurkatMinArea_um2 / pixelArea_um2)));
        Jlab = bwlabel(J, 8);  nJ = max(Jlab(:));
        Jeng = false(size(ch1));  Jfree = false(size(ch1));
        if nJ > 0
            Jd   = imdilate(Jlab, strel('disk', ringWidth_px));
            ring = Jd > 0 & ~J;
            ringFrac = accumarray(Jd(ring), double(bw1(ring)), [nJ 1], @mean);
            overFrac = accumarray(Jlab(J),  double(bw1(J)),    [nJ 1], @mean);
            isEng = ringFrac >= engulfRingFrac | overFrac >= engulfOverlapFrac;
            Jeng  = ismember(Jlab, find(isEng));
            Jfree = ismember(Jlab, find(~isEng));
        end
        JfreeX = imdilate(Jfree, strel('disk', jurkatExclude_px + 1));
        bw1 = (bw1 | Jeng) & ~JfreeX;

        h1  = imfill(bw1, 'holes') & ~bw1;                     % fill small holes only
        bw1 = bw1 | (h1 & ~bwareaopen(h1, maxHole_px + 1));
        bw1 = bwareaopen(bw1, max(1, round(minCellArea_px / 2)));

        %% ---- Nuclei (seeds) ----
        r3  = imgaussfilt(mat2gray(ch3, double(prctile(ch3(:), [0.5 99.8]))), gaussianSigma);
        bwN = r3 > nucThreshScale * graythresh(r3);
        bwN = imfill(imopen(bwN, strel('disk', 1)), 'holes');
        JnucZone = imdilate(Jeng | Jfree, strel('disk', 2));   % remove Jurkat nuclei
        bwN = bwareaopen(bwN & ~JnucZone, minNuc_px);
        if any(bwN(:))                                         % split touching nuclei
            Dn  = imgaussfilt(bwdist(~bwN), 1);
            mkN = imextendedmax(Dn, nucSplitH) & bwN;
            Lw  = watershed(imimposemin(-Dn, mkN));
            bwN(Lw == 0 & bwN) = false;
            bwN = bwareaopen(bwN, minNuc_px);
        end
        NL = bwlabel(bwN, 4);

        %% ---- Seeds ----
        D1      = imgaussfilt(bwdist(~bw1), 1);
        seedsCT = imextendedmax(D1, seedH) & bw1;              % CellTrace seeds (fallback)
        seeds   = imerode(NL > 0, ones(3));                    % one seed per nucleus

        %% ---- Foreground (CellTrace OR phalloidin) ----
        ch4_proc = imgaussfilt(adapthisteq(mat2gray(ch4)), gaussianSigma);
        bw4 = ch4_proc > ch4ThreshScale * graythresh(ch4_proc);
        fg  = imclose(bw4 | bw1, strel('disk', seRadius));
        fg  = (fg | Jeng) & ~JfreeX;
        holes = imfill(fg, 'holes') & ~fg;
        fg    = fg | (holes & ~bwareaopen(holes, maxHole_px + 1));
        ch4only = fg & ~bw1;                                   % remove wide dim gap haze
        thick   = imopen(ch4only, strel('disk', extRadius_px));
        dimGap  = imopen(thick & ~ch4bright, strel('disk', 1));
        fg      = fg & ~dimGap;
        fg      = bwareaopen(fg, minDebris_px);
        fg_all  = fg;                                          % excluded from background

        seeded = imreconstruct(seeds & fg, fg);                % fallback seeds
        orphan = bwareaopen(fg & ~seeded, max(1, round(seedFallbackMinArea_um2 / pixelArea_um2)));
        seeds  = seeds | (seedsCT & orphan);
        fg = imreconstruct(seeds & fg, fg);                    % keep seeded objects only

        %% ---- Seeded watershed ----
        ridge = mat2gray(ch4_proc);
        shape = mat2gray(-bwdist(~fg));
        land  = ridgeWeight * ridge + (1 - ridgeWeight) * shape;
        land(~fg) = 2;
        land  = imimposemin(land, seeds & fg);
        L0 = double(watershed(land));
        L0(~fg) = 0;

        %% ---- Remove gap pixels ----
        sig = r1 > gapThreshScale_ch1 * graythresh(r1) | ch4pos;
        sig = imclose(sig, strel('disk', 1));
        hs  = imfill(sig, 'holes') & ~sig;
        sig = sig | (hs & ~bwareaopen(hs, maxHole_px + 1));
        sig = (sig | Jeng) & ~JfreeX;
        L0(~sig) = 0;
        CC = bwlabel(L0 > 0, 4);                               % keep largest piece per cell
        if any(CC(:))
            compLab  = accumarray(CC(CC > 0), L0(CC > 0), [], @max);
            compArea = accumarray(CC(CC > 0), 1);
            [~, ord] = sortrows([compLab, compArea], [1 -2]);
            [~, firstIdx] = unique(compLab(ord), 'first');
            keepComp = false(numel(compLab), 1);
            keepComp(ord(firstIdx)) = true;
            L0(CC > 0 & ~keepComp(max(CC, 1))) = 0;
        end

        %% ---- Refine outer edges with phalloidin ----
        if edgeRefine_px > 0 && any(L0(:))
            ch1core = r1 > graythresh(r1);
            keepJ   = imdilate(Jeng, strel('disk', 1));
            [bgPix, ~] = outerBackground(L0);
            rimPix = L0 > 0 & imdilate(bgPix, strel('disk', 3)) & ~keepJ;
            bgFar  = bgPix & ~imdilate(L0 > 0, strel('disk', 10)) & ~JfreeX;
            if nnz(bgFar) > 100, bgv = median(r4(bgFar)); else, bgv = prctile(r4(:), 5); end
            rimv    = prctile(r4(rimPix), 90);
            thrEdge = bgv + edgeHalfMax * (rimv - bgv);
            for k = 1:edgeRefine_px                            % peel
                [bgPix, ~] = outerBackground(L0);
                outer = L0 > 0 & imdilate(bgPix, ones(3));
                rem   = outer & r4 < thrEdge & ~ch1core & ~keepJ;
                if ~any(rem(:)), break; end
                L0(rem) = 0;
            end
            growable = r4 >= thrEdge & ~JfreeX;
            for k = 1:edgeRefine_px                            % grow
                [~, Lmax, Lmin] = outerBackground(L0);
                add = L0 == 0 & growable & Lmax > 0 & Lmax == Lmin;
                if ~any(add(:)), break; end
                L0(add) = Lmax(add);
            end
        end

        %% ---- Size filter, relabel ----
        if any(L0(:))
            a0 = accumarray(L0(L0 > 0), 1);
            L0(ismember(L0, find(a0 > 0 & a0 < minCellArea_px))) = 0;
        end
        L = zeros(size(L0));
        if any(L0(:))
            [~, ~, newID] = unique(L0(L0 > 0));
            L(L0 > 0) = newID;
        end
        nCells = max(L(:));
        fprintf('    %d cells\n', nCells);

        %% ---- Phalloidin measurements ----
        JengX = imdilate(Jeng, strel('disk', jurkatExclude_px));   % excluded from ch4
        bgMask = ~imdilate(fg_all | bw1 | Jeng | Jfree, strel('disk', bgExclusion_px));
        if any(bgMask(:)), bg = median(ch4(bgMask)); else, bg = 0; end

        Din   = bwdist(L == 0);                  % distance to nearest cell edge
        meas  = L > 0 & ~JengX;
        band1 = meas & Din <= periph_px;         % 1 um periphery
        bandR = meas & Din <= ratio_px;          % 1.5 um periphery (ratio)
        intR  = meas & Din >  ratio_px;          % interior for the ratio

        if nCells > 0
            cellMean = @(m) accumarray(L(m), ch4(m), [nCells 1]) ./ accumarray(L(m), 1, [nCells 1]) - bg;
            area_um2  = accumarray(L(L > 0), 1, [nCells 1]) * pixelArea_um2;
            mArea_um2 = accumarray(L(meas),  1, [nCells 1]) * pixelArea_um2;
            wholeMean = cellMean(meas);
            periph1   = cellMean(band1);
            ratioPI   = cellMean(bandR) ./ cellMean(intR);     % NaN if no interior

            cellResults = [cellResults; table( ...
                repmat({filename}, nCells, 1), repmat(p, nCells, 1), (1:nCells)', ...
                area_um2, mArea_um2, repmat(bg, nCells, 1), wholeMean, periph1, ratioPI, ...
                'VariableNames', {'ImageName', 'Position', 'CellID', ...
                'Area_Cell_um2', 'Area_Measured_um2', 'Ch4_Background', ...
                'Ch4_Mean', 'Ch4_Periph_Mean_1um', 'Ch4_Periph_Interior_Ratio'})]; %#ok<AGROW>
            fieldVals = [mean(wholeMean, 'omitnan'), mean(periph1, 'omitnan'), median(ratioPI, 'omitnan')];
        else
            fieldVals = [NaN NaN NaN];
        end

        % per-field values as used for the Prism experiment means
        summaryResults = [summaryResults; table({filename}, p, pixelSize_um, nCells, bg, ...
            fieldVals(1), fieldVals(2), fieldVals(3), ...
            'VariableNames', {'ImageName', 'Position', 'PixelSize_um', 'N_Cells', 'Ch4_Background', ...
            'Ch4_Mean_FieldMean', 'Ch4_Periph_Mean_1um_FieldMean', ...
            'Ch4_Periph_Interior_Ratio_FieldMedian'})]; %#ok<AGROW>

        %% ---- Masks and QC overlay ----
        imwrite(uint16(L), fullfile(outputDir, sprintf('%s_cells_p%03d.tif', baseName, p)));
        % QC: phalloidin = magenta, CellTrace = green, cell edges = white,
        % inner edge of 1 um band = yellow, nuclei = blue,
        % engulfed Jurkats = orange outline, free Jurkats = grey outline
        ch1_n = mat2gray(ch1, double(prctile(ch1(:), [1 99.5])));
        ch4_n = mat2gray(ch4, double(prctile(ch4(:), [1 99.5])));
        R = ch4_n;  G = 0.6 * ch1_n;  B = ch4_n;
        inner = bwperim(L > 0 & Din > periph_px);
        edgeC = L > 0 & Din < 1.5;
        R(inner) = 1; G(inner) = 1; B(inner) = 0;
        R(edgeC) = 1; G(edgeC) = 1; B(edgeC) = 1;
        e = bwperim(Jeng);    R(e) = 1;   G(e) = 0.55; B(e) = 0;
        e = bwperim(NL > 0);  R(e) = 0.2; G(e) = 0.5;  B(e) = 1;
        e = bwperim(Jfree);   R(e) = 0.6; G(e) = 0.6;  B(e) = 0.6;
        imwrite(uint8(cat(3, R, G, B) * 255), fullfile(outputDir, sprintf('%s_QC_p%03d.tif', baseName, p)));
    end
end

writetable(cellResults,    fullfile(outputDir, 'cell_measurements.csv'));
writetable(summaryResults, fullfile(outputDir, 'field_summary.csv'));
fprintf('DONE: analysis complete.\n');

%% ================= LOCAL FUNCTIONS =================
function [bgPix, Lmax, Lmin] = outerBackground(L)
% Background pixels that are NOT 1-px borders between two touching cells,
% plus the max / min neighbouring label of every pixel (3x3).
Lmax = imdilate(L, ones(3));
tmp  = L;  tmp(tmp == 0) = Inf;
Lmin = imerode(tmp, ones(3));
border = L == 0 & Lmax > 0 & Lmin < Inf & Lmax ~= Lmin;
bgPix  = L == 0 & ~border;
end
