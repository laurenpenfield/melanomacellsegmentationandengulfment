%% ============================================================================
%  RED-GREEN CONTACT & ENGULFMENT TIMELAPSE ANALYSIS 

%  Green is used ONLY as a mask (no individual green cells, no green shape,
%  no green velocity). Red cells are segmented in every frame; they are NOT
%  tracked as individual cells. Whether an engulfment persists, and whether it
%  is new, is judged by location (same place in consecutive frames).
%
%  Every red object gets a STATE in every frame:
%     F = free      not within contactDist_px of green
%     T = touching  within contactDist_px of green, no overlap
%     P = partial   in contact with green but not engulfed
%     I = inside    engulfed: surrounded by green (insideRule, default 'ring')
%                   AND bright (engulfMode) AND at the same place for
%                   >= engulfMinFrames frames
%
%  Outputs (in outputDir):
%   summary_timecourse.csv          one row per timepoint per movie: red counts
%                                   per state, % in contact, % inside, sizes,
%                                   engulfed area, contact length, new
%                                   engulfments and cumulative engulfments
%   movie_summary.csv               one row per movie (totals / first / last)
%   run_log.txt                     which movies were processed / failed
%   <file>_red_objects.csv          every red object in every frame (state,
%                                   raw state, size, brightness, why not engulfed)
%   <file>_QC_stack.tif + _QC_movie.avi   overlay, red outlines coloured by state
%   <file>_QCred_stack.tif + _QCred_movie.avi   red channel only (grey), outlines
%                                   by state, reason labels on partial cells
%   <file>_green/_redall/_redinside_stack.tif   masks
%   (with makePlots = true also: _timecourse, _red_sizes, _red_brightness,
%    _page_check PNGs)
%
%  Channel 3 (if present) is never read.
%% ============================================================================

%% ================= USER SETTINGS =================
inputDir  = 'data/images';
outputDir = 'data/output';

% Channels per timepoint in the TIF: 2 (green + red) or 3 (green + red + an
% extra channel that is never read). Works for both.
nChannels = 2;
greenIdx  = 1;     % physical channel used as green
redIdx    = 2;     % physical channel used as red
% true  = if the file's metadata (ImageJ / OME-TIFF) states the number of channels
%         and the page order, use those for that file (so 2- and 3-channel files
%         can be mixed in one folder). nChannels / pageOrder are the fallback.
% false = always use nChannels / pageOrder, and stop if the metadata disagrees.
useMetadataLayout = true;

% Page interleaving:  'CT' = T1C1, T1C2, T1C3, T2C1 ...  (usual ZEN export)
%                     'TC' = C1T1, C1T2, ... C2T1 ...
pageOrder       = 'CT';
verifyPageOrder = false;   % true = write first pages labelled with assumed channel/time
% Stop if a channel's brightness alternates every other timepoint (sign of wrong
% nChannels / pageOrder / Z-slices). A <file>_page_check.png is always written.
stopOnPageProblem = true;

% Timing
frameInterval_min = 60;    % minutes between frames
t0_offset_min     = 0;

% Pixel size (um/px). [] = read from metadata. Setting it is recommended.
pixelSize_um_override = [];

%% ---- Intensity / threshold ----
intensityScaling    = 'series';  % 'series' (comparable over time) or 'frame'
gaussianSigma_green = 1;
gaussianSigma_red   = 1;

thresholdMode     = 'series';    % 'series' (one threshold for the movie) | 'frame' | 'manual'
greenManualThresh = 0.25;        % only used with thresholdMode = 'manual'
redManualThresh   = 0.35;

%% ---- RED threshold ----
%   'background' (recommended) threshold = background + redBgK x noise.
%                Not affected by how bright the brightest cells are.
%                Assumes red cells cover < ~half the image.
%   'otsu'       Otsu x redThreshScale. A few very bright cells pull Otsu up.
redThreshMethod = 'background';
redBgK          = 6;      % was 5. HIGHER = less background (and fewer dim cells). ~4 permissive, 6-8 strict
redThreshScale  = 1.0;    % extra multiplier on the final red threshold (<1 = lower)
% BACKGROUND FILTER: a red object is kept only if its BRIGHTEST pixel reaches
% redMinPeakRatio on the brightness scale (same numbers as engulfBrightRatio and
% the labels in the red-only QC). Background patches only just cross the
% threshold and have no bright peak; real cells do. Kept cells keep their full
% outline. Raise to remove more background, lower if dim real cells vanish; 0 = off.
redMinPeakRatio = 4;      % was 3
% HAZE / uneven background: subtract a smooth background before thresholding
% (removes glow and large dim patches, keeps cells). Set to ~2-3x a red cell's
% DIAMETER in um (e.g. 25-40 for ~12 um cells); 0 = off. Compare with tuneMode = 'red'.
redBackgroundRadius_um = 25;   % ON by default: removes haze / uneven red background

%% ---- GREEN threshold ----
%   'stepotsu'    (default) the original Otsu, but if the pixels BELOW the Otsu
%                 threshold still split cleanly into background + dim cells
%                 (because very bright cells pulled Otsu up), Otsu is repeated on
%                 those pixels. x greenThreshScale. On images without very bright
%                 cells it gives exactly the original Otsu.
%   'otsu'        original: Otsu x greenThreshScale.
%   'background'  background + greenBgK x noise. Most sensitive; can pick up
%                 haze around cells.
%   'logotsu'     Otsu on log intensities x greenThreshScale.
greenThreshMethod = 'stepotsu';
greenThreshScale  = 0.7;   % 'stepotsu' / 'otsu' / 'logotsu': lower = bigger green mask
greenStepSep      = 12;    % 'stepotsu': how clearly dim cells must stand out from background
                           % (in background-noise units) to take the extra step. LOWER (8) =
                           % steps down more readily: finds dimmer cells but more glow;
                           % HIGHER = closer to plain Otsu
greenBgK          = 8;     % 'background' only: LOWER = more / dimmer green
% Uneven green background: subtract a smooth background first, ~2-3x a green
% cell's DIAMETER in um; 0 = off.
greenBackgroundRadius_um = 0;

%% ---- Green mask cleanup ----
greenDilate_px  = 1;     % grow green mask slightly (0 = off)
greenClose_px   = 3;     % close small breaks in green (0 = off)
greenMinArea_px = 100;   % remove green specks smaller than this

%% ---- TUNING (optional; runs on the FIRST file only, then STOPS) ----
% Saves side-by-side QC panels <file>_tune_<mode>_t###.png and counts
% <file>_tune_<mode>.csv for a few frames. Pick the best panel, copy its
% setting below, set tuneMode = 'off' and run normally.
%   'off'       normal full analysis
%   'red'       compare complete red settings (tuneRedSettings)          <- start here for red background
%   'green'     compare green threshold methods / values (tuneGreenSettings) <- start here for green
%   'threshold' compare redBgK values (tuneRedBgK)
%   'peak'      compare redMinPeakRatio values (tuneMinPeak)
%   'rule'      compare the three insideRule options
%   'inside'    compare red thresholds inside green (tuneInsideFactors)
%   'bright'    compare engulfBrightRatio values (tuneBrightRatios)
%   'split'     compare red watershed / shape filter settings (tuneSplitSettings)
%   'refine'    compare redRefineFrac values (cells merged with background haze)
tuneMode = 'off';
% each row: [redBgK  redMinPeakRatio  redBackgroundRadius_um]
tuneRedSettings = [ 5  3   0;
                    6  4   0;
                    8  5   0;
                    6  4  30;
                    8  5  30 ];
% each entry: {greenThreshMethod, value}; value = greenThreshScale for the Otsu
% methods, greenBgK for 'background'
tuneGreenSettings = { {'otsu', 0.7}, {'stepotsu', 0.7}, {'stepotsu', 0.5}, ...
                      {'otsu', 0.5}, {'background', 12} };
tuneRedBgK        = [5 6 7 8 10];
tuneMinPeak       = [0 3 4 5 6];
tuneRedScales     = [0.5 0.6 0.75 0.9 1.0];    % 'threshold' with 'otsu' / 'manual' red
tuneInsideFactors = [1.0 0.8 0.6 0.5];
tuneBrightRatios  = [3 3.5 4 5 6];
% each row: [redSplitDepth_um  redMinSolidity  redMaxArea_um2]
tuneSplitSettings = [ 0    0    Inf;
                      1.0  0.8  300;
                      1.5  0.8  300;
                      2.5  0.8  300;
                      1.5  0.9  200 ];
tuneRefineFracs   = [0 0.2 0.3 0.4 0.5];     % 'refine': redRefineFrac values
tuneFrames        = [];                         % timepoints to show; [] = 4 evenly spaced

%% ---- Red objects: size ----
% Red objects smaller than redMinArea_um2 are treated as noise and ignored.
% Objects from redMinArea_um2 up to redCellMinArea_um2 are kept as FRAGMENTS
% (e.g. engulfed pieces); larger ones are CELLS. Both are analysed; counts are
% also reported separately for cells and fragments.
% (1 um2 ~ a spot 1.1 um across; 25 um2 ~ 5.6 um across.)
redMinArea_um2     = 2;
redCellMinArea_um2 = 25;

%% ---- Red (Jurkat) segmentation: splitting and shape ----
% Fill dark centres so a cell with a dim middle stays one object.
redFillHoles = true;
% WATERSHED split of touching red cells at the narrow "neck" between them.
% redSplitDepth_um = how much narrower the neck must be than the cells for a
% split (in um). Smaller = splits more readily (can cut single cells in two);
% larger = only clearly separate cells are split. 0 = no splitting.
% Jurkats (~10-12 um across): start at 1.5.
redSplitDepth_um = 1.5;
% Typical area of ONE red cell. Objects still bigger than ~1.6x this after the
% first split (e.g. tight clusters of 3+) are split again with a gentler neck
% requirement until the pieces are cell-sized. A Jurkat is ~80-120 um2.
redCellArea_um2 = 100;
% SHAPE / SIZE FILTER for cell-sized objects (fragments below redCellMinArea_um2
% are not shape-filtered):
%   redMinSolidity: area / area of its convex outline. Round cells ~0.9+,
%   irregular background shapes much lower. 0 = off.
%   redMaxArea_um2: objects bigger than this after splitting (clumps that would
%   not split, large background patches) are removed. Inf = off.
%   A single Jurkat is ~80-120 um2.
redMinSolidity = 0.8;
redMaxArea_um2 = 300;
% REFINE objects that merged with surrounding background haze: any object that
% is too big (> 1.6x redCellArea_um2) or irregular (solidity < redMinSolidity)
% is re-cut at its OWN brightness: background + redRefineFrac x (its peak -
% background). The bright cell keeps a compact core, the dim haze falls away.
% Dimmer cells in the leftover are recovered with their own edge if they have a
% clear peak (>= redMinPeakRatio); leftover haze is dropped. This happens
% after watershed splitting and BEFORE the size / shape filters, so real cells
% are no longer removed with the haze. Higher = tighter outlines. 0 = off.
redRefineFrac = 0.3;
redRefineAll  = false;   % true = re-cut EVERY red object at its own brightness

%% ---- Red threshold inside green ----
% Engulfed red material is often dimmer (e.g. quenched in acidic compartments).
% Inside green (holes filled in), red is detected at threshold x this factor.
% 1 = same threshold everywhere; 0.7 = 30% lower inside green.
% Compare values with tuneMode = 'inside'.
redInsideThreshFactor = 1.0;

%% ---- Contact / engulfment rules ----
% Touching = red edge within contactDist_px of green (0 = must overlap)
contactDist_px = 2;

% How "fully inside" (engulfed) is decided. An engulfed red cell usually leaves a
% HOLE in the green signal, so red pixels sit in that hole, not on green pixels.
%   'ring'     (recommended) look in a thin ring just OUTSIDE the red cell
%              (ringWidth_px wide) and measure how far AROUND the cell green
%              is found (36 directions; a dark gap does not lower the score):
%                >= insideRingFrac            -> I inside (surrounded by green)
%                >= partialRingFrac or overlap -> P partial (e.g. phagocytic cup)
%              Works even if the green ring has small gaps.
%   'centroid' red cell's CENTRE lies in green, with holes in green filled in -> I.
%              Simple, but a red cell lying on top of a green cell also counts.
%   'whole'    every red pixel lies in green with holes filled in -> I.
%              Needs a completely closed green ring around the cell.
insideRule      = 'ring';
ringWidth_px    = 3;      % should reach across any dark gap between red cell and green
insideRingFrac  = 0.80;   % green on >= 80% of the way around -> inside
partialRingFrac = 0.30;   % green on >= 30% of the way around -> partial
% 'whole' only: grow green by this many px for the test (1-2 forgives edge pixels)
insideTolerance_px = 0;

%% ---- Engulfment BRIGHTNESS (red gets brighter once it is engulfed) ----
%   'geometry'        inside = insideRule only (surrounded by green)
%   'geometry+bright' inside = surrounded by green AND bright   (default)
%                     surrounded but still dim -> counted as partial
%   'bright'          inside = bright AND in any contact with green
%                     (use if brightening is the most reliable sign)
engulfMode = 'geometry+bright';
% "Bright" = the red object's peak intensity, above background, is at least
% engulfBrightRatio x (4 x background noise). The reference is FIXED, so changing
% redBgK (which cells are detected) does not change what counts as bright.
% (With 'otsu' or 'manual' red thresholds the reference is the red threshold.)
% Look at <file>_red_brightness.png to see where engulfed and non-engulfed
% cells separate, or compare values with tuneMode = 'bright'.
engulfBrightRatio = 15;   

%% ---- Engulfment must PERSIST (by location - no cell tracking) ----
% An engulfment call only counts if an engulfed red object stays at the SAME
% PLACE for at least engulfMinFrames consecutive frames: in each next frame an
% inside object must be found within engulfMatchDist_um of where it was (the
% position is followed frame to frame, so slow drift with the phagocyte is fine).
% Up to engulfGapFrames frames in a row may be missing (e.g. one dim frame)
% without breaking the run (they don't count toward its length).
% Shorter inside episodes (passing over/under green, flicker) count as PARTIAL.
% Applies to every count, engulfed area and the QC images. 1 = off.
% With 60-min frames, 3 = must stay inside for 3 h.
engulfMinFrames    = 3;
engulfMatchDist_um = 8;
engulfGapFrames    = 1;
% An inside episode still going at the END of the movie but shorter than
% engulfMinFrames: false = not counted (can't be confirmed), true = counted.
engulfCountUnfinished = false;
% NEW engulfment events (N_Engulfed, Cum_Engulfed): a confirmed engulfed object
% with no confirmed engulfed object within engulfMatchDist_um in the previous
% 1 + engulfGapFrames frames. Engulfments already present in frame 1 are not
% new events.

%% ---- Output ----
saveMasks       = true;
saveQC          = true;
% MATLAB plots (timecourse, engulfment, sizes, brightness, page check PNGs).
% false = no plot windows / PNGs; all numbers are still in the CSV files.
% (Tuning mode always makes its comparison panels.)
makePlots       = false;
imageOutputMode = 'stack';  % 'stack' = one time-ordered TIF per output, 'separate' = one per frame
saveQCMovie     = true;
qcMovieFPS      = 5;
% Red-only QC: red channel in grey + red outlines by state
% (<file>_QCred_stack.tif and <file>_QCred_movie.avi)
saveRedQC          = true;
% Label next to red cells in the red-only QC (drawn with a built-in pixel font,
% so no Computer Vision Toolbox is needed):
%   'reason'     ORANGE cells only - why they are not engulfed:
%                  D2.8 = dim (brightness 2.8, needs engulfBrightRatio)
%                  R65  = green only 65% of the way around (needs insideRingFrac)
%                  T    = surrounded and bright, but inside too few frames
%   'brightness' every cell: brightness score
%   'none'
qcRedLabel         = 'reason';
qcLabelScale       = 2;             % size of the pixel-font labels (1 = tiny, 3 = large)
qcRedShowGreenEdge = false;         % true = also draw the green mask edge (dark green)
qcRedShowRemoved   = true;          % outline objects removed by the background / shape /
                                    % size filters in BLUE (to check the filters)

%% ---- QC display (changes only how QC images LOOK, not any measurement) ----
qcSaturatePct = 0.5;   % % of brightest pixels shown at full brightness. Higher = brighter image (try 1-3)
qcBlackPct    = 5;     % % of darkest pixels shown as black. Higher = darker background
qcGamma       = 0.7;   % < 1 lifts dim signal (0.5 = strong), 1 = linear
qcGreenGain   = 1.0;   % extra display brightness per channel (e.g. 1.5)
qcRedGain     = 1.0;
% Outline thickness in the QC images / movies, in pixels (1 = thin, as before).
% Applies to the green mask edge, the red state outlines and the blue "removed"
% outlines. Only changes how the QC looks, not any measurement.
qcOutlineWidth_px = 3;

%% ================= SETUP =================
if ~exist(outputDir, 'dir'); mkdir(outputDir); end
if any([greenIdx redIdx] < 1); error('greenIdx and redIdx must be 1 or higher.'); end
if greenIdx == redIdx; error('greenIdx and redIdx must be different.'); end
usedChannels = [greenIdx redIdx];
fprintf('Green = channel %d, red = channel %d.\n', greenIdx, redIdx);

files = [dir(fullfile(inputDir, '*.tif')); dir(fullfile(inputDir, '*.tiff')); ...
         dir(fullfile(inputDir, '*.TIF')); dir(fullfile(inputDir, '*.TIFF'))];
if isempty(files); error('No .tif / .tiff files found in %s', inputDir); end
[~, iu] = unique({files.name});  files = files(sort(iu));        % (Windows lists some twice)
fprintf('%d movie(s) found in %s\n', numel(files), inputDir);

frameInterval_h = frameInterval_min / 60;
if ~any(strcmpi(insideRule, {'ring', 'centroid', 'whole'}))
    error('insideRule must be ''ring'', ''centroid'' or ''whole''.');
end
if ~any(strcmpi(redThreshMethod, {'background', 'otsu'}))
    error('redThreshMethod must be ''background'' or ''otsu''.');
end
ruleOpts = struct('rule', lower(insideRule), 'tol', insideTolerance_px, 'ringWidth', ringWidth_px, ...
                  'insideFrac', insideRingFrac, 'partialFrac', partialRingFrac, ...
                  'insideFactor', redInsideThreshFactor, ...
                  'engulfMode', lower(engulfMode), 'brightRatio', engulfBrightRatio, 'bg', 0, 'thrMain', 1, ...
                  'minPeak', redMinPeakRatio, 'fillHoles', redFillHoles, 'splitH', 0, ...
                  'minSolidity', redMinSolidity, 'maxAreaPx', Inf, 'cellMinPx', 0, 'cellAreaPx', Inf, ...
                  'refineFrac', redRefineFrac, 'refineAll', redRefineAll);
if ~any(strcmpi(greenThreshMethod, {'stepotsu', 'otsu', 'background', 'logotsu'}))
    error('greenThreshMethod must be ''stepotsu'', ''otsu'', ''background'' or ''logotsu''.');
end
if ~any(strcmpi(engulfMode, {'geometry', 'geometry+bright', 'bright'}))
    error('engulfMode must be ''geometry'', ''geometry+bright'' or ''bright''.');
end
dispOpts = struct('gamma', qcGamma, 'gGain', qcGreenGain, 'rGain', qcRedGain, 'lineW', qcOutlineWidth_px);
fprintf('Inside rule: %s\n', ruleOpts.rule);
stateCodes      = 'FTPI';
stateColors     = [0.7 0.7 0.7; 1 1 0; 1 0.5 0; 0 1 1];   % outline: F grey, T yellow, P orange, I cyan
stateColorsRed  = [1 0 1; 1 1 0; 1 0.5 0; 0 1 1];         % red-only QC (grey image): F magenta
hasInsertText   = exist('insertText', 'file') == 2;

R = struct([]);  rowN = 0;
MSall = table();      % one row per movie (movie_summary.csv)
processed = {};  failed = {};

%% ================= LOOP OVER FILES =================
for f = 1:numel(files)
  fileRowStart = rowN;  okFile = false;
  try   % one movie failing must not stop the others

    filename = files(f).name;
    fprintf('\n=== %s  (movie %d of %d) ===\n', filename, f, numel(files));
    imgPath  = fullfile(inputDir, filename);
    [~, baseName] = fileparts(filename);

    info = imfinfo(imgPath);

    %% >>> v7: keep only full-resolution image pages. Some exports add
    % thumbnail / reduced-resolution pages, which shift every page after them.
    W = [info.Width];  H = [info.Height];
    isMain = (W == max(W)) & (H == max(H));
    if isfield(info, 'NewSubFileType')
        nsf = zeros(1, numel(info));
        for k = 1:numel(info)
            if ~isempty(info(k).NewSubFileType); nsf(k) = double(info(k).NewSubFileType); end
        end
        isMain = isMain & bitand(nsf, 1) == 0;         % bit 0 = reduced-resolution copy
    end
    pages  = find(isMain);
    nPages = numel(pages);
    if nPages < numel(info)
        fprintf('  Skipping %d thumbnail / reduced-resolution page(s).\n', numel(info) - nPages);
    end

    pixelSize_um  = getPixelSize(info(pages(1)), pixelSize_um_override);
    pixelArea_um2 = pixelSize_um^2;
    redMinPx      = floor(redMinArea_um2 / pixelArea_um2) + 1;
    ruleOpts.splitH    = redSplitDepth_um / pixelSize_um;       % red segmentation, in pixels
    ruleOpts.maxAreaPx = redMaxArea_um2 / pixelArea_um2;
    ruleOpts.cellMinPx = redCellMinArea_um2 / pixelArea_um2;
    ruleOpts.cellAreaPx = redCellArea_um2 / pixelArea_um2;

    %% >>> v7: compare settings with what the file's own metadata says
    meta  = readLayoutFromMetadata(info(pages(1)));
    nCh   = nChannels;       % layout used for THIS file
    order = pageOrder;
    if ~isnan(meta.C)
        fprintf('  Metadata (%s): channels=%d, slices=%s, frames=%s, order=%s\n', meta.src, meta.C, ...
            num2str(meta.Z), num2str(meta.T), meta.order);
        if ~isnan(meta.Z) && meta.Z > 1
            error(['%s: the file has %d Z-slices per timepoint. The script expects one image per ' ...
                   'channel per timepoint, so slices would be read as timepoints/channels. ' ...
                   'Export a max projection (or a single slice) and rerun.'], filename, meta.Z);
        end
        if useMetadataLayout
            nCh = meta.C;
            if ~isempty(meta.order); order = meta.order; end
        else
            if meta.C ~= nChannels
                error(['%s: the file says it has %d channels but nChannels = %d. This makes ' ...
                       'channels swap between timepoints. Set nChannels = %d.'], filename, meta.C, nChannels, meta.C);
            end
            if ~isempty(meta.order) && ~strcmpi(meta.order, pageOrder)
                error('%s: the file stores pages in ''%s'' order but pageOrder = ''%s''. Set pageOrder = ''%s''.', ...
                    filename, meta.order, pageOrder, meta.order);
            end
        end
    else
        fprintf('  No channel layout in metadata - using nChannels = %d, pageOrder = ''%s''.\n', nChannels, pageOrder);
    end
    if any(usedChannels > nCh)
        error('%s has %d channel(s), but greenIdx = %d and redIdx = %d.', filename, nCh, greenIdx, redIdx);
    end
    extra = setdiff(1:nCh, usedChannels);
    if isempty(extra)
        fprintf('  Using %d channels (green = %d, red = %d).\n', nCh, greenIdx, redIdx);
    else
        fprintf('  Using %d channels (green = %d, red = %d); not read: %s\n', nCh, greenIdx, redIdx, num2str(extra));
    end

    %% ---- Page layout ----
    if mod(nPages, nCh) ~= 0
        error('Pages (%d) not divisible by nCh (%d).', nPages, nCh);
    end
    nT = nPages / nCh;
    fprintf('  Image pages: %d | Timepoints: %d | order: %s\n', nPages, nT, order);
    k = (1:nPages)';
    if strcmpi(order, 'CT')
        pageIdx = @(c,t) pages((t-1)*nCh + c);
        pc = mod(k-1, nCh) + 1;   pt = floor((k-1)/nCh) + 1;
    elseif strcmpi(order, 'TC')
        pageIdx = @(c,t) pages((c-1)*nT + t);
        pc = floor((k-1)/nT) + 1;       pt = mod(k-1, nT) + 1;
    else
        error('order must be ''CT'' or ''TC''.');
    end

    if verifyPageOrder
        for k = 1:min(2*nCh, nPages)
            imwrite(imread(imgPath, pages(k)), fullfile(outputDir, ...
                sprintf('%s_PAGE%02d_assumed_c%d_t%d.tif', baseName, k, pc(k), pt(k))));
        end
        fprintf('  Wrote first pages labelled with assumed channel/timepoint.\n');
    end

    [imH, imW] = size(imread(imgPath, pages(1)));
    fieldArea_um2 = imH * imW * pixelArea_um2;

    %% ---- PASS A: read every page once: intensity range + page check ----
    pMean = zeros(nPages,1);  pMin = pMean;  pMax = pMean;  pLoD = pMean;  pHiD = pMean;
    for k = 1:nPages
        I = double(imread(imgPath, pages(k)));
        pMean(k) = mean(I(:));  pMin(k) = min(I(:));  pMax(k) = max(I(:));
        v = sort(I(1:4:end));  nv = numel(v);                 % QC display range (every 4th pixel is plenty)
        pLoD(k) = v(max(1, round(qcBlackPct / 100 * nv)));
        pHiD(k) = v(max(1, round((1 - qcSaturatePct / 100) * nv)));
    end
    lo = inf(1, nCh);  hi = -inf(1, nCh);
    if strcmpi(intensityScaling, 'series')
        for c = usedChannels
            lo(c) = min(pMin(pc == c));  hi(c) = max(pMax(pc == c));
        end
    end
    dLo = zeros(1, nCh);  dHi = ones(1, nCh);                 % QC display black / white levels
    for c = usedChannels
        dLo(c) = median(pLoD(pc == c));
        dHi(c) = max(median(pHiD(pc == c)), dLo(c) + 1);
    end

    %% >>> v7: flag an every-other-frame pattern in the brightness of a channel.
    % A real channel changes smoothly over time; if frame-to-frame jumps are
    % much bigger than jumps two frames apart, pages are being mis-assigned.
    alternating = false;
    for c = usedChannels
        m = pMean(pc == c);                        % this channel, in time order
        if numel(m) >= 6
            d1 = median(abs(diff(m)));
            d2 = median(abs(m(3:end) - m(1:end-2)));
            if d1 > 3 * max(d2, eps) && d1 > 0.05 * median(m)
                alternating = true;
                warning(['%s: channel %d brightness alternates every other timepoint ' ...
                         '(lag-1 change %.1f vs lag-2 change %.1f). nChannels, pageOrder or ' ...
                         'Z-slices are probably wrong - see %s_page_check.png.'], ...
                         filename, c, d1, d2, baseName);
            end
        end
    end
    % Also check how often the page brightness REPEATS. With channel-fastest
    % ('CT') pages, the pattern repeats every <true number of channels> pages.
    % This catches e.g. a 3-channel file read as 2 channels (repeats every 3).
    if strcmpi(order, 'CT') && nPages >= 12
        nTry  = 1:min(6, floor(nPages/3));
        rough = arrayfun(@(n) median(abs(pMean(1+n:end) - pMean(1:end-n))), nTry);
        nBest = find(rough <= 1.5 * min(rough) + eps, 1);     % smallest repeat length
        if nBest ~= nCh && mod(nBest, nCh) ~= 0 && ...
                rough(nCh) > 3 * max(rough(nBest), eps) && rough(nCh) > 0.05 * median(pMean)
            alternating = true;
            warning(['%s: page brightness repeats every %d pages, which suggests %d channels per ' ...
                     'timepoint, but %d are being used. Set nChannels = %d (or check the export). ' ...
                     'See %s_page_check.png.'], filename, nBest, nBest, nCh, nBest, baseName);
        end
    end
    if makePlots   % the page-layout warning above is printed either way
        plotPageCheck(pMean, pc, pt, nCh, greenIdx, redIdx, baseName, outputDir, alternating);
    end
    if alternating && stopOnPageProblem
        error('Stopped: fix the page layout, or set stopOnPageProblem = false to continue anyway.');
    end

    redBgRad_px   = round(redBackgroundRadius_um   / pixelSize_um);
    greenBgRad_px = round(greenBackgroundRadius_um / pixelSize_um);
    prep = @(I, c, sig) localPrep(I, c, sig, intensityScaling, lo, hi, ...
        (c == redIdx) * redBgRad_px + (c == greenIdx) * greenBgRad_px);

    %% ---- PASS B: thresholds ----
    switch lower(thresholdMode)
        case 'series'
            gS = zeros(nT,5); otR = zeros(nT,1); bgR = zeros(nT,1); nzR = zeros(nT,1);
            for t = 1:nT
                gS(t,:) = greenStats(prep(double(imread(imgPath, pageIdx(greenIdx,t))), greenIdx, gaussianSigma_green), greenStepSep);
                [otR(t), bgR(t), nzR(t)] = redStats(prep(double(imread(imgPath, pageIdx(redIdx,t))), redIdx, gaussianSigma_red));
            end
            gStat = median(gS, 1);       % [Otsu, log-Otsu, background, noise, step Otsu]
            thrG  = greenThreshold(greenThreshMethod, gStat, greenThreshScale, greenBgK);
            fprintf(['    green candidates: Otsu x%.2f = %.4f | step Otsu x%.2f = %.4f | ' ...
                     'background + %g x noise = %.4f  -> using %s = %.4f\n'], ...
                greenThreshScale, gStat(1) * greenThreshScale, greenThreshScale, gStat(5) * greenThreshScale, ...
                greenBgK, gStat(3) + greenBgK * gStat(4), greenThreshMethod, thrG);
            redOtsu = median(otR);  redBg = median(bgR);  redNoise = median(nzR);
            thrR = redThreshold(redThreshMethod, redOtsu, redBg, redNoise, redThreshScale, redBgK);
            fprintf('  Green threshold %.4f | red threshold %.4f (%s)\n', thrG, thrR, redThreshMethod);
            fprintf('    red: background %.4f, noise %.4f -> bg + %g x noise = %.4f | Otsu = %.4f\n', ...
                redBg, redNoise, redBgK, redBg + redBgK * redNoise, redOtsu);
        case 'manual'
            thrG = greenManualThresh;  thrR = redManualThresh;
        case 'frame'
            thrG = [];  thrR = [];
        otherwise
            error('thresholdMode must be ''series'', ''frame'' or ''manual''.');
    end

    %% ---- TUNING (optional; stops the script) ----
    if ~strcmpi(tuneMode, 'off')
        if isempty(tuneFrames)
            tf = unique(round(linspace(1, nT, min(4, nT))));
        else
            tf = tuneFrames(tuneFrames >= 1 & tuneFrames <= nT);
        end
        % each variant changes one thing; empty / NaN = current setting
        base = struct('redK', [], 'redScale', [], 'redFull', [], 'minPeak', redMinPeakRatio, ...
                      'rule', insideRule, 'inFac', redInsideThreshFactor, 'bright', engulfBrightRatio, ...
                      'green', {{}}, 'split', [], 'refine', [], 'label', '');
        V = {};
        switch lower(tuneMode)
            case 'red'
                for r = 1:size(tuneRedSettings, 1)
                    v = base;  v.redFull = tuneRedSettings(r,:);
                    v.label = sprintf('red K %g | peak>=%g | bgsub %g um', tuneRedSettings(r,:));  V{end+1} = v; %#ok<AGROW>
                end
            case 'green'
                for r = 1:numel(tuneGreenSettings)
                    v = base;  v.green = tuneGreenSettings{r};
                    v.label = sprintf('green %s %g', v.green{1}, v.green{2});  V{end+1} = v; %#ok<AGROW>
                end
            case 'threshold'
                if strcmpi(redThreshMethod, 'background') && ~strcmpi(thresholdMode, 'manual')
                    for x = tuneRedBgK;    v = base; v.redK = x;     v.label = sprintf('red K %g', x);       V{end+1} = v; end %#ok<AGROW>
                else
                    for x = tuneRedScales; v = base; v.redScale = x; v.label = sprintf('red x%.2f', x);      V{end+1} = v; end %#ok<AGROW>
                end
            case 'peak'
                for x = tuneMinPeak;       v = base; v.minPeak = x;  v.label = sprintf('red peak>=%g', x);  V{end+1} = v; end %#ok<AGROW>
            case 'rule'
                for r = {'whole', 'centroid', 'ring'}; v = base; v.rule = r{1}; v.label = ['rule ' r{1}];  V{end+1} = v; end %#ok<AGROW>
            case 'inside'
                for x = tuneInsideFactors; v = base; v.inFac = x;    v.label = sprintf('inside x%.2f', x);  V{end+1} = v; end %#ok<AGROW>
            case 'bright'
                for x = tuneBrightRatios;  v = base; v.bright = x;   v.label = sprintf('bright>=%g', x);    V{end+1} = v; end %#ok<AGROW>
            case 'split'
                for r = 1:size(tuneSplitSettings, 1)
                    v = base;  v.split = tuneSplitSettings(r,:);
                    v.label = sprintf('split %g um | solidity>=%g | max %g um2', tuneSplitSettings(r,:));  V{end+1} = v; %#ok<AGROW>
                end
            case 'refine'
                for x = tuneRefineFracs;   v = base; v.refine = x;   v.label = sprintf('refine %g', x);     V{end+1} = v; end %#ok<AGROW>
            otherwise
                error('tuneMode must be off, red, green, split, refine, threshold, peak, rule, inside or bright.');
        end

        TT = struct([]);  n = 0;
        for t = tf
            G  = double(imread(imgPath, pageIdx(greenIdx,t)));
            Rd = double(imread(imgPath, pageIdx(redIdx,t)));
            Gp = prep(G,  greenIdx, gaussianSigma_green);
            Rp = prep(Rd, redIdx,   gaussianSigma_red);
            gSt = greenStats(Gp, greenStepSep);
            switch lower(thresholdMode)
                case 'series'
                    thrG_t = thrG;  ot = redOtsu;  bg = redBg;  nz = redNoise;  thrNow = thrR;
                case 'manual'
                    thrG_t = thrG;  [ot, bg, nz] = redStats(Rp);  thrNow = thrR;
                otherwise
                    thrG_t = greenThreshold(greenThreshMethod, gSt, greenThreshScale, greenBgK);
                    [ot, bg, nz] = redStats(Rp);
                    thrNow = redThreshold(redThreshMethod, ot, bg, nz, redThreshScale, redBgK);
            end
            nV  = numel(V);
            fig = figure('Color', 'w', 'Renderer', 'painters', 'Position', [30 80 min(1900, 380*nV) 480]);
            for i = 1:nV
                v = V{i};
                % ---- green ----
                if isempty(v.green)
                    thrGv = thrG_t;
                else
                    thrGv = greenThreshold(v.green{1}, gSt, v.green{2}, v.green{2});
                end
                [bwG, bwG_near] = makeGreenMask(Gp, thrGv, greenDilate_px, greenClose_px, greenMinArea_px, contactDist_px);
                % ---- red ----
                RpV = Rp;  bgV = bg;  nzV = nz;  minPeak = v.minPeak;
                if ~isempty(v.redFull)                         % complete red setting
                    RpV = localPrep(Rd, redIdx, gaussianSigma_red, intensityScaling, lo, hi, ...
                                    round(v.redFull(3) / pixelSize_um));
                    [~, bgV, nzV] = redStats(RpV);             % this frame (full run uses whole movie)
                    thr = bgV + v.redFull(1) * nzV;  minPeak = v.redFull(2);
                    ref = bgV + 4 * nzV;
                elseif ~isempty(v.redK)
                    thr = (bg + v.redK * nz) * redThreshScale;
                    ref = brightReference(redThreshMethod, thresholdMode, bg, nz, thrNow);
                elseif ~isempty(v.redScale)
                    if strcmpi(thresholdMode, 'manual'); thr = redManualThresh * v.redScale; else; thr = ot * v.redScale; end
                    ref = brightReference(redThreshMethod, thresholdMode, bg, nz, thrNow);
                else
                    thr = thrNow;
                    ref = brightReference(redThreshMethod, thresholdMode, bg, nz, thrNow);
                end
                opts = ruleOpts;  opts.rule = v.rule;  opts.insideFactor = v.inFac;  opts.brightRatio = v.bright;
                opts.bg = bgV;  opts.thrMain = ref;  opts.minPeak = minPeak;
                if ~isempty(v.split)
                    opts.splitH = v.split(1) / pixelSize_um;  opts.minSolidity = v.split(2);
                    opts.maxAreaPx = v.split(3) / pixelArea_um2;
                end
                if ~isempty(v.refine); opts.refineFrac = v.refine; end
                [~, Lr, Sr, st, aPx] = classifyRed(RpV, thr, redMinPx, bwG, bwG_near, opts);

                subplot(1, nV, i);
                imshow(makeOverlay(G, Rd, dLo, dHi, greenIdx, redIdx, dispOpts, bwG, Lr, st, stateColors));
                frag = aPx * pixelArea_um2 < redCellMinArea_um2;
                title(sprintf('%s\ngreen %.0f%% of image | red %d: free %d touch %d partial %d INSIDE %d', ...
                    v.label, 100 * mean(bwG(:)), numel(st), sum(st==0), sum(st==1), sum(st==2), sum(st==3)), ...
                    'FontSize', 8, 'Interpreter', 'none');
                n = n + 1;
                TT(n).ImageName         = string(filename);
                TT(n).Timepoint         = t;
                TT(n).Setting           = string(v.label);
                TT(n).GreenThreshold    = thrGv;
                TT(n).GreenCoverage_pct = 100 * mean(bwG(:));
                TT(n).RedThreshold      = thr;
                TT(n).RedMinPeakRatio   = minPeak;
                TT(n).N_Red             = numel(Sr);
                TT(n).N_Free            = sum(st == 0);
                TT(n).N_Touching        = sum(st == 1);
                TT(n).N_Partial         = sum(st == 2);
                TT(n).N_Inside          = sum(st == 3);
                TT(n).N_Fragments       = sum(frag);
                TT(n).MeanRedArea_um2   = meanOrNaN(aPx * pixelArea_um2);
            end
            sgtitle(sprintf('%s  t%d  -  white = green mask | grey free | yellow touching | orange partial | cyan inside', ...
                baseName, t), 'FontSize', 10, 'Interpreter', 'none');
            saveFig(fig, fullfile(outputDir, sprintf('%s_tune_%s_t%03d.png', baseName, lower(tuneMode), t)));
            close(fig);
        end
        writetable(struct2table(TT), fullfile(outputDir, sprintf('%s_tune_%s.csv', baseName, lower(tuneMode))));
        fprintf(['\nTuning (%s) written for %s, frames %s.\n' ...
                 'Open %s_tune_%s_t###.png, copy the best setting into the settings,\n' ...
                 'set tuneMode = ''off'' and run again.\n'], tuneMode, filename, num2str(tf), baseName, lower(tuneMode));
        return
    end

    %% ---- per-file state ----
    rowsCell = cell(1, nT);    % per-object rows, one cell per timepoint

    stk.QC        = fullfile(outputDir, sprintf('%s_QC_stack.tif',        baseName));
    stk.green     = fullfile(outputDir, sprintf('%s_green_stack.tif',     baseName));
    stk.redall    = fullfile(outputDir, sprintf('%s_redall_stack.tif',    baseName));
    stk.redinside = fullfile(outputDir, sprintf('%s_redinside_stack.tif', baseName));
    stk.QCred     = fullfile(outputDir, sprintf('%s_QCred_stack.tif',     baseName));
    if strcmpi(imageOutputMode, 'stack')       % clear old runs
        fn = fieldnames(stk);
        for k = 1:numel(fn)
            if exist(stk.(fn{k}), 'file'); delete(stk.(fn{k})); end
        end
    end
    % stack writers stay OPEN for the whole movie (appending with imwrite re-reads
    % the growing file every frame, which gets very slow for long movies)
    W = struct();
    W.QC        = stackInit(stk.QC,        imH * imW * 3 * nT);
    W.QCred     = stackInit(stk.QCred,     imH * imW * 3 * nT);
    W.green     = stackInit(stk.green,     imH * imW * nT);
    W.redall    = stackInit(stk.redall,    imH * imW * nT);
    W.redinside = stackInit(stk.redinside, imH * imW * nT);
    tm = zeros(1, 5);   % timing: read+prep, segment, rows, (unused), masks+QC

    % masks / QC are written with a short delay so each frame can use the
    % CONFIRMED engulfment calls (needs engulfMinFrames - 1 later frames)
    qLag = max(0, (engulfMinFrames - 1) * (1 + engulfGapFrames));
    Q = {};  H = cell(1, nT);  rowStart = rowN + 1;     % H{t} = [x_um y_um rawState] per object
    P = struct('saveMasks', saveMasks, 'saveQC', saveQC, 'saveRedQC', saveRedQC, 'hasText', hasInsertText, ...
        'redLabel', qcRedLabel, 'redShowGreen', qcRedShowGreenEdge, ...
        'redShowRemoved', qcRedShowRemoved, 'brightCut', engulfBrightRatio, 'dLo', dLo, 'dHi', dHi, ...
        'greenIdx', greenIdx, 'redIdx', redIdx, 'disp', dispOpts, 'stateColors', stateColors, ...
        'stateColorsRed', stateColorsRed, 'outputDir', outputDir, 'baseName', baseName, ...
        'mode', imageOutputMode, 'N', engulfMinFrames, 'gap', engulfGapFrames, ...
        'matchDist', engulfMatchDist_um, 'nT', nT, ...
        'countUnfinished', engulfCountUnfinished, 'labelScale', qcLabelScale, 'ringCut', insideRingFrac);
    vw = [];
    if saveQC && saveQCMovie
        vw = VideoWriter(fullfile(outputDir, sprintf('%s_QC_movie.avi', baseName)), 'Motion JPEG AVI');
        vw.FrameRate = qcMovieFPS;  vw.Quality = 95;
        open(vw);
    end
    vwR = [];
    if saveRedQC && saveQCMovie
        vwR = VideoWriter(fullfile(outputDir, sprintf('%s_QCred_movie.avi', baseName)), 'Motion JPEG AVI');
        vwR.FrameRate = qcMovieFPS;  vwR.Quality = 95;
        open(vwR);
    end

    %% ================= TIMEPOINT LOOP =================
    for t = 1:nT
        elapsed_h = (t0_offset_min + (t-1)*frameInterval_min) / 60;
        tk = tic;
        G  = double(imread(imgPath, pageIdx(greenIdx,t)));
        Rd = double(imread(imgPath, pageIdx(redIdx,t)));
        Gp = prep(G,  greenIdx, gaussianSigma_green);
        Rp = prep(Rd, redIdx,   gaussianSigma_red);
        if strcmpi(thresholdMode, 'frame')
            thrG_t = greenThreshold(greenThreshMethod, greenStats(Gp, greenStepSep), greenThreshScale, greenBgK);
            [ot, bg, nz] = redStats(Rp);
            thrR_t = redThreshold(redThreshMethod, ot, bg, nz, redThreshScale, redBgK);
        else
            thrG_t = thrG;  thrR_t = thrR;
        end

        tm(1) = tm(1) + toc(tk);  tk = tic;
        %% ---- green MASK + red objects / states ----
        [bwG, bwG_near] = makeGreenMask(Gp, thrG_t, greenDilate_px, greenClose_px, greenMinArea_px, contactDist_px);
        areaG_um2 = sum(bwG(:)) * pixelArea_um2;
        if strcmpi(thresholdMode, 'series'); bgF = redBg; nzF = redNoise; else; [~, bgF, nzF] = redStats(Rp); end
        o = ruleOpts;  o.bg = bgF;                              % brightness is measured above this background
        o.thrMain = brightReference(redThreshMethod, thresholdMode, bgF, nzF, thrR_t);
        [bwR, Lr, Sr, redState, redAreaPx, rm] = classifyRed(Rp, thrR_t, redMinPx, bwG, bwG_near, o);
        nRed = numel(Sr);
        isFrag = redAreaPx * pixelArea_um2 < redCellMinArea_um2;   % small pieces vs whole cells

        tm(2) = tm(2) + toc(tk);  tk = tic;
        Cr = reshape([Sr.Centroid], 2, [])';
        if isempty(Cr); Cr = zeros(0,2); end

        % length of red boundary in contact with green (touching + partial cells)
        Simg = stateImage(Lr, redState);                         % 0 bg, 1 F, 2 T, 3 P, 4 I
        bwContact = Simg == 2 | Simg == 3;
        contactLen_um = sum(sum(bwperim(bwContact) & bwG_near)) * pixelSize_um;
        bwInside  = Simg == 4;

        %% ---- per-object rows ----
        fr = struct([]);
        for k = nRed:-1:1                % last first = preallocated
            fr(k).ImageName       = string(filename);
            fr(k).Timepoint       = t;
            fr(k).Elapsed_h       = elapsed_h;
            fr(k).ObjectID        = k;
            fr(k).State           = redState(k);
            fr(k).StateLabel      = string(stateCodes(redState(k) + 1));
            fr(k).FracOnGreen       = rm.fracOnGreen(k);    % red pixels on green signal
            fr(k).FracInFilledGreen = rm.fracInFilled(k);   % ... counting holes in green as green
            fr(k).CentroidInGreen   = rm.centroidIn(k);     % centre in green (holes filled)
            fr(k).RingGreenFrac     = rm.ringFrac(k);       % fraction of surrounding ring that is green
            fr(k).GeomInside        = rm.geomInside(k);     % surrounded by green (insideRule only)
            fr(k).RedPeak           = Sr(k).MaxIntensity;   % peak red (processed image, 0-1)
            fr(k).RedMean           = Sr(k).MeanIntensity;
            fr(k).BrightRatio       = rm.brightRatio(k);    % peak above bg / (4 x noise); see engulfBrightRatio
            fr(k).Bright            = rm.bright(k);
            fr(k).Area_um2        = redAreaPx(k) * pixelArea_um2;
            if isFrag(k); fr(k).SizeClass = "fragment"; else; fr(k).SizeClass = "cell"; end
            fr(k).EquivDiam_um    = Sr(k).EquivDiameter   * pixelSize_um;   % diameter of a circle of equal area
            fr(k).MajorAxis_um    = Sr(k).MajorAxisLength * pixelSize_um;   % longest axis of fitted ellipse
            fr(k).MinorAxis_um    = Sr(k).MinorAxisLength * pixelSize_um;
            fr(k).X_um            = Cr(k,1) * pixelSize_um;
            fr(k).Y_um            = Cr(k,2) * pixelSize_um;
        end
        rowsCell{t} = fr;

        tm(3) = tm(3) + toc(tk);  tk = tic;
        %% ---- masks + QC: queued, written once engulfment persistence is known ----
        Q{end+1} = struct('t', t, 'elapsed_h', elapsed_h, 'G', single(G), 'Rd', single(Rd), ...
            'bwG', bwG, 'bwR', bwR, 'Lr', uint32(Lr), 'state', redState, 'xy', Cr * pixelSize_um, 'Cr', Cr, ...
            'bright', rm.brightRatio, 'bwDropped', rm.bwDropped, 'thr', thrR_t, ...
            'ring', rm.ringFrac, 'geom', rm.geomInside); %#ok<AGROW>
        H{t} = [Cr * pixelSize_um, redState(:)];
        while ~isempty(Q) && Q{1}.t <= t - qLag
            W = writeQCFrame(Q{1}, H, t, false, P, W, vw, vwR);
            Q(1) = [];
        end
        tm(5) = tm(5) + toc(tk);
        if mod(t, 10) == 0 || t == nT; fprintf('  t %d / %d\n', t, nT); end
        %% ---- summary row ----
        nC = sum(redState == 1 | redState == 2);
        rowN = rowN + 1;
        R(rowN).ImageName            = string(filename);
        R(rowN).Timepoint            = t;
        R(rowN).Elapsed_h            = elapsed_h;
        R(rowN).PixelSize_um         = pixelSize_um;
        R(rowN).Thresh_Green         = thrG_t;
        R(rowN).Thresh_Red           = thrR_t;
        R(rowN).Area_Green_um2       = areaG_um2;
        R(rowN).Coverage_Green_Frac  = areaG_um2 / fieldArea_um2;
        R(rowN).N_Red                = nRed;
        R(rowN).N_Red_Free           = sum(redState == 0);
        R(rowN).N_Red_Touching       = sum(redState == 1);
        R(rowN).N_Red_Partial        = sum(redState == 2);
        R(rowN).N_Red_Inside         = sum(redState == 3);
        R(rowN).N_Red_Inside_Raw     = sum(redState == 3);         % before the persistence rule
        R(rowN).N_Red_InContact      = nC;                          % touching + partial
        R(rowN).Frac_Red_InContact   = nC / max(nRed, 1);
        R(rowN).Frac_Red_Inside      = sum(redState == 3) / max(nRed, 1);
        R(rowN).Area_Red_Inside_um2  = sum(redAreaPx(redState == 3)) * pixelArea_um2;
        R(rowN).N_Red_Cells          = sum(~isFrag);
        R(rowN).N_Red_Fragments      = sum(isFrag);
        R(rowN).N_Inside_Cells       = sum(redState == 3 & ~isFrag);
        R(rowN).N_Inside_Fragments   = sum(redState == 3 & isFrag);
        % red object SIZES in this frame (um2), all objects and by state
        aUm = redAreaPx * pixelArea_um2;
        R(rowN).MeanArea_Red_um2       = meanOrNaN(aUm);
        R(rowN).MedianArea_Red_um2     = medianOrNaN(aUm);
        R(rowN).MedianArea_Free_um2    = medianOrNaN(aUm(redState == 0));
        R(rowN).MedianArea_Contact_um2 = medianOrNaN(aUm(redState == 1 | redState == 2));
        R(rowN).MedianArea_Inside_um2  = medianOrNaN(aUm(redState == 3));
        R(rowN).MeanArea_Inside_um2    = meanOrNaN(aUm(redState == 3));
        % all red pixels within green (holes filled), regardless of object size
        % or state (= cyan + the in-green part of orange objects in the QC)
        R(rowN).Area_Red_InFilledGreen_um2 = sum(bwR(:) & rm.bwGf(:)) * pixelArea_um2;
        % ENGULFED area relative to green area. Green area here includes the holes
        % that engulfed red cells sit in (filled green), so the denominator is the
        % green cells' full footprint. Only cyan (engulfed) objects in the numerator.
        areaGf_um2 = sum(rm.bwGf(:)) * pixelArea_um2;
        R(rowN).Area_Green_Filled_um2       = areaGf_um2;
        R(rowN).Engulfed_per_GreenArea_pct  = 100 * sum(redAreaPx(redState == 3)) * pixelArea_um2 / max(areaGf_um2, eps);
        % per mm2 of green footprint and free-or-contact counts: filled in after
        % the movie, once the engulfment calls are confirmed
        R(rowN).Engulfed_Objects_per_mm2_Green   = NaN;
        R(rowN).Engulfed_Cells_per_mm2_Green     = NaN;
        R(rowN).Engulfed_Fragments_per_mm2_Green = NaN;
        R(rowN).N_Red_FreeOrContact    = NaN;
        R(rowN).N_Cells_FreeOrContact  = NaN;
        R(rowN).Frac_Red_FreeOrContact = NaN;
        R(rowN).Contact_Length_um    = contactLen_um;
        R(rowN).N_Engulfed           = NaN;      % filled in after the movie (needs later frames)
        R(rowN).Cum_Engulfed         = NaN;
    end

    while ~isempty(Q)                                   % write the remaining delayed frames
        W = writeQCFrame(Q{1}, H, nT, true, P, W, vw, vwR);
        Q(1) = [];
    end
    if ~isempty(vw);  close(vw);  end
    if ~isempty(vwR); close(vwR); end
    fn = fieldnames(W);
    for k = 1:numel(fn); W.(fn{k}) = stackClose(W.(fn{k})); end
    nonEmpty = rowsCell(~cellfun(@isempty, rowsCell));
    if isempty(nonEmpty); rRows = struct([]); else; rRows = [nonEmpty{:}]; end
    fprintf('  %d timepoints done. Time (s): read %.0f | segment %.0f | rows %.0f | masks+QC %.0f\n', ...
        nT, tm([1 2 3 5]));

    %% ---- per-file outputs ----
    if ~isempty(rRows)
        RT = struct2table(rRows);
        RT = sortrows(RT, {'Timepoint', 'ObjectID'});
        % persistence rule (by location) + new-engulfment events; all per-frame
        % counts for this movie are recomputed from the final states
        [RT, R] = finalizeEngulfment(RT, R, rowStart:rowStart + nT - 1, nT, H, P);
        fprintf('  Persistence (>= %d frames at the same place): inside calls %d -> %d\n', engulfMinFrames, ...
            sum(RT.StateRaw == 3), sum(RT.State == 3));
        safeWriteTable(RT, fullfile(outputDir, sprintf('%s_red_objects.csv', baseName)));
        MS = movieSummary(R(rowStart:rowStart + nT - 1), filename);
        MSall = [MSall; MS]; %#ok<AGROW>
        fprintf('  New engulfments: %d | engulfed in first frame %d, last frame %d\n', ...
            MS.New_Engulfments, MS.Inside_FirstFrame, MS.Inside_LastFrame);
        if makePlots
            plotSizes(RT, baseName, outputDir, redMinArea_um2, redCellMinArea_um2);
            plotBrightness(RT, baseName, outputDir, engulfBrightRatio);
        end
    end
    okFile = true;

  catch err
    ln = 0;  if ~isempty(err.stack); ln = err.stack(1).line; end
    failed{end+1} = sprintf('%s: %s (line %d)', files(f).name, err.message, ln); %#ok<SAGROW>
    fprintf(2, '  !! %s FAILED: %s (line %d)\n  -> skipped; continuing with the next movie\n', ...
        files(f).name, err.message, ln);
    try; if exist('vw', 'var')  && ~isempty(vw);  close(vw);  end; catch; end    % close open writers
    try; if exist('vwR', 'var') && ~isempty(vwR); close(vwR); end; catch; end
    try; if exist('W', 'var'); fnw = fieldnames(W); for k = 1:numel(fnw); W.(fnw{k}) = stackClose(W.(fnw{k})); end; end; catch; end
    R = R(1:fileRowStart);  rowN = fileRowStart;                               % drop its partial rows
  end
  if okFile; processed{end+1} = files(f).name; end %#ok<SAGROW>

  % save the summaries after EVERY movie, so a later problem can't lose them
  if rowN > 0
      safeWriteTable(struct2table(R(1:rowN)), fullfile(outputDir, 'summary_timecourse.csv'));
  end
  if ~isempty(MSall)
      safeWriteTable(MSall, fullfile(outputDir, 'movie_summary.csv'));
  end
end

%% ================= SAVE / REPORT =================
fprintf('\n================ DONE ================\n');
fprintf('Processed %d of %d movie(s); summary_timecourse.csv has %d rows.\n', numel(processed), numel(files), rowN);
if ~isempty(failed)
    fprintf(2, 'FAILED (not in the summary):\n');
    fprintf(2, '  %s\n', failed{:});
end
fid = fopen(fullfile(outputDir, 'run_log.txt'), 'w');
if fid > 0
    fprintf(fid, 'Run finished %s\nProcessed (%d):\n', datestr(now), numel(processed));
    if ~isempty(processed); fprintf(fid, '  %s\n', processed{:}); end
    fprintf(fid, 'Failed (%d):\n', numel(failed));
    if ~isempty(failed); fprintf(fid, '  %s\n', failed{:}); end
    fclose(fid);
end
if rowN > 0; results = struct2table(R(1:rowN)); else; results = table(); end

%% ================= TIMECOURSE PLOTS =================
if isempty(results); uf = []; else; uf = unique(results.ImageName); end
for i = 1:numel(uf) * makePlots          % skipped when makePlots = false
    sub = results(results.ImageName == uf(i), :);
    x = sub.Elapsed_h;
    figure('Name', char(uf(i)), 'Color', 'w', 'Renderer', 'painters', 'Position', [100 100 1100 700]);

    subplot(2,2,1);
    plot(x, sub.N_Red_Free, '-', 'Color', [0.6 0.6 0.6], 'LineWidth', 1.3); hold on;
    plot(x, sub.N_Red_Touching, '-', 'Color', [0.9 0.75 0], 'LineWidth', 1.3);
    plot(x, sub.N_Red_Partial,  '-', 'Color', [1 0.5 0],    'LineWidth', 1.3);
    plot(x, sub.N_Red_Inside,   '-', 'Color', [0.55 0.1 0.6], 'LineWidth', 1.6);
    xlabel('Elapsed (h)'); ylabel('red cells');
    legend('free','touching','partial','fully inside','Location','best');
    title('Red cells by state'); grid on;

    subplot(2,2,2);
    plot(x, sub.Frac_Red_InContact*100, '-o', 'Color', [1 0.5 0], 'LineWidth', 1.2); hold on;
    plot(x, sub.Frac_Red_Inside*100,    '-s', 'Color', [0.55 0.1 0.6], 'LineWidth', 1.2);
    xlabel('Elapsed (h)'); ylabel('% of red cells');
    legend('in contact (touching + partial)','fully inside','Location','best');
    title('Contact and engulfment'); grid on;

    subplot(2,2,3);
    bar(x, sub.N_Engulfed);
    xlabel('Elapsed (h)'); ylabel('new engulfments per frame');
    title('New engulfments'); grid on;

    subplot(2,2,4);
    yyaxis left;  plot(x, sub.Cum_Engulfed, '-', 'LineWidth', 1.6); ylabel('cumulative engulfed');
    yyaxis right; plot(x, sub.Engulfed_per_GreenArea_pct, '--', 'LineWidth', 1.3); ylabel('engulfed area / green area (%)');
    xlabel('Elapsed (h)'); title('Cumulative engulfment & engulfed area'); grid on;

    saveFig(gcf, fullfile(outputDir, sprintf('%s_timecourse.png', regexprep(char(uf(i)), '\.tiff?$', '', 'ignorecase'))));
end

%% ================= HELPERS =================
function P = localPrep(I, c, sig, scaling, lo, hi, bgRadius)
    if strcmpi(scaling, 'series')
        P = min(max((I - lo(c)) / max(hi(c) - lo(c), eps), 0), 1);
    else
        P = mat2gray(I);
    end
    if bgRadius > 0; P = imtophat(P, strel('disk', bgRadius)); end   % remove uneven background
    if sig > 0; P = imgaussfilt(P, sig); end
end

function [ot, bg, nz] = redStats(Rp)
% Otsu level, background level (median) and background noise (robust SD) of a frame.
    v  = Rp(:);
    ot = graythresh(Rp);
    bg = median(v);
    nz = 1.4826 * median(abs(v - bg));
    if nz <= 1e-6                          % e.g. flat / clipped background
        vs = sort(v);
        nz = std(vs(1:max(2, round(0.75 * numel(vs)))));
    end
    nz = max(nz, 1e-6);
end

function gs = greenStats(Gp, stepSep)
% Green threshold candidates: gs = [Otsu, log-Otsu, background, noise, step Otsu]
    v   = Gp(:);
    ot  = otsuVec(v);
    off = 1e-3;
    L   = log(v + off);
    otLog = exp(otsuVec(L)) - off;
    [bg, nz] = darkPeakBackground(v);
    % step Otsu: while the pixels below the threshold still split into two groups
    % that are far apart in units of BACKGROUND noise (background + dim cells, or
    % glow of very bright cells + the rest), move the threshold down to that split.
    % Splitting plain background noise gives ~1.6 noise units, so it stops there.
    t = ot;
    for it = 1:5
        lower = v(v < t);
        if numel(lower) < 1000; break; end
        t2 = otsuVec(lower);
        a = lower(lower <  t2);  b = lower(lower >= t2);
        if numel(b) < 50 || numel(a) < 100; break; end
        sep = (median(b) - median(a)) / nz;
        if sep >= stepSep
            t = t2;
        else
            break
        end
    end
    gs = [ot, otLog, bg, nz, t];
end

function [t, eta] = otsuVec(v)
% Otsu threshold of a vector of values (256-bin histogram) and its
% effectiveness eta = between-class / total variance (1 = perfect split).
    v = v(:);  lo = min(v);  hi = max(v);
    if hi <= lo; t = lo; eta = 0; return; end
    nb  = 256;
    idx = min(nb, floor((v - lo) / (hi - lo) * nb) + 1);
    p   = accumarray(idx, 1, [nb 1]) / numel(v);
    c   = ((1:nb)' - 0.5) / nb * (hi - lo) + lo;           % bin centres
    w0  = cumsum(p);  mu0 = cumsum(p .* c);  muT = mu0(end);
    sB  = (muT * w0 - mu0).^2 ./ max(w0 .* (1 - w0), eps);
    [sBmax, k] = max(sB(1:end-1));
    t   = c(k) + 0.5 * (hi - lo) / nb;                    % upper edge of class 0
    sT  = sum(p .* (c - muT).^2);
    eta = sBmax / max(sT, eps);
end

function [bg, nz] = darkPeakBackground(v)
% Background level = the darkest PROMINENT peak of the intensity histogram
% (the curve must dip clearly after it), so ripples on the background's dark
% edge are ignored. Noise = robust SD of the pixels darker than that peak, so
% dim cells (even covering most of the image) and bright cells do not affect it.
    % histogram of the darker half of the pixels only: it always contains the
    % background, and very bright cells cannot stretch the bins too wide
    v  = v(:);  vs = sort(v(1:4:end));  n = numel(vs);      % percentiles from every 4th pixel
    lo = vs(max(1, round(0.001 * n)));  hi = vs(max(1, round(0.5 * n)));
    if hi <= lo; bg = median(v); nz = max(1.4826 * median(abs(v - bg)), 1e-6); return; end
    nb = 256;  w = (hi - lo) / nb;
    bg = firstProminentPeak(v, lo, hi, nb);
    nz = darkSideSD(v, bg, lo);
    if nz < 2 * w
        % peak narrower than ~2 bins: refine using pixels close to it
        near = v(abs(v - bg) <= 2 * w);
        if numel(near) > 100; bg = median(near); end
        nz = darkSideSD(v(v >= bg - 3 * w), bg, bg - 3 * w);
    end
    nz = max(nz, 1e-6);
end

function pkVal = firstProminentPeak(v, lo, hi, nb)
    idx = min(nb, max(1, floor((v(v >= lo & v <= hi) - lo) / (hi - lo) * nb) + 1));
    h   = accumarray(idx, 1, [nb 1]);
    k   = exp(-((-6:6)' / 2.5).^2 / 2);  k = k / sum(k);      % gentle smoothing
    h   = conv(h, k, 'same');
    cand = find(h(2:end-1) >= h(1:end-2) & h(2:end-1) >= h(3:end) & h(2:end-1) >= 0.1 * max(h)) + 1;
    pk = [];
    for c = cand'
        nxt = find(h(c+1:end) >= h(c), 1);              % where the curve climbs back to this height
        if isempty(nxt); seg = h(c+1:end); else; seg = h(c+1:c+nxt); end
        if ~isempty(seg) && min(seg) <= 0.7 * h(c)      % clear dip after it -> a real peak
            pk = c;  break
        end
    end
    if isempty(pk); [~, pk] = max(h); end
    pkVal = lo + (pk - 0.5) / nb * (hi - lo);
end

function nz = darkSideSD(v, bg, lo)
    dark = v(v <= bg & v >= lo);
    if numel(dark) < 50
        nz = 1.4826 * median(abs(v - median(v)));
    else
        nz = 1.4826 * median(bg - dark);
    end
end

function thr = greenThreshold(method, gs, scale, K)
% gs = [Otsu, log-Otsu, background, noise, step Otsu]
    switch lower(method)
        case 'otsu',        thr = gs(1) * scale;
        case 'logotsu',     thr = gs(2) * scale;
        case 'stepotsu',    thr = gs(3) + (gs(5) - gs(3)) * scale;   % scale applied above background
        otherwise,          thr = gs(3) + K * gs(4);     % 'background'
    end
end

function thr = redThreshold(method, ot, bg, nz, scale, K)
    if strcmpi(method, 'otsu')
        thr = ot * scale;
    else
        thr = (bg + K * nz) * scale;
    end
end

function meta = readLayoutFromMetadata(info1)
% Channel / slice / frame counts and page order from ImageJ or OME-TIFF metadata.
    meta = struct('C', NaN, 'Z', NaN, 'T', NaN, 'order', '', 'src', '');
    d = '';
    if isfield(info1, 'ImageDescription'); d = info1.ImageDescription; end
    if isempty(d) && isfield(info1, 'Comment'); d = info1.Comment; end   % some readers use Comment
    if iscell(d); if isempty(d); d = ''; else; d = d{1}; end; end
    if isempty(d) || ~ischar(d); return; end
    if contains(d, 'ImageJ=')
        meta.src = 'ImageJ';
        meta.C = getNum(d, 'channels=(\d+)', 1);
        meta.Z = getNum(d, 'slices=(\d+)',   1);
        meta.T = getNum(d, 'frames=(\d+)',   NaN);
        meta.order = 'CT';                        % ImageJ hyperstacks: channel varies fastest
    elseif contains(d, '<OME')
        meta.src = 'OME';
        meta.C = getNum(d, 'SizeC="(\d+)"', NaN);
        meta.Z = getNum(d, 'SizeZ="(\d+)"', NaN);
        meta.T = getNum(d, 'SizeT="(\d+)"', NaN);
        tok = regexp(d, 'DimensionOrder="(\w+)"', 'tokens', 'once');
        if ~isempty(tok)
            o = tok{1};
            if strfind(o, 'C') < strfind(o, 'T'); meta.order = 'CT'; else; meta.order = 'TC'; end
        end
    end
end

function v = getNum(d, pat, default)
    tok = regexp(d, pat, 'tokens', 'once');
    if isempty(tok); v = default; else; v = str2double(tok{1}); end
end

function plotPageCheck(pMean, pc, pt, nC, gIdx, rIdx, baseName, outputDir, flagged)
% Mean brightness of every page, coloured by the channel the script ASSUMES it is.
% Correct layout: each colour is a smooth line. Wrong layout: colours zig-zag.
    fig = figure('Name', [baseName ' page check'], 'Color', 'w', 'Renderer', 'painters', 'Position', [100 100 1100 600]);
    cols = lines(nC);
    subplot(2,1,1); hold on;
    for c = 1:nC
        k = find(pc == c);
        plot(k, pMean(k), 'o', 'Color', cols(c,:), 'MarkerFaceColor', cols(c,:), 'MarkerSize', 4);
    end
    xlabel('page in TIF'); ylabel('mean intensity');
    legend(arrayfun(@(c) sprintf('assumed channel %d', c), 1:nC, 'UniformOutput', false), 'Location', 'best');
    title('Every page, coloured by assumed channel'); grid on;
    subplot(2,1,2); hold on;
    for c = [gIdx rIdx]
        k = find(pc == c);
        plot(pt(k), pMean(k), '-o', 'Color', cols(c,:), 'MarkerSize', 3, 'LineWidth', 1.1);
    end
    xlabel('timepoint'); ylabel('mean intensity');
    legend(sprintf('green (channel %d)', gIdx), sprintf('red (channel %d)', rIdx), 'Location', 'best');
    if flagged
        title('WARNING: alternating pattern - page layout is probably wrong', 'Color', [0.8 0 0]);
    else
        title('Analysed channels over time (should be smooth)');
    end
    grid on;
    saveFig(fig, fullfile(outputDir, sprintf('%s_page_check.png', baseName)));
    close(fig);
end

function [bwG, bwG_near] = makeGreenMask(Gp, thr, dil, clo, minA, contactDist)
% Green mask, plus the mask grown by contactDist (used for "touching").
    bwG = Gp > thr;
    if dil > 0; bwG = imdilate(bwG, strel('disk', dil)); end
    if clo > 0; bwG = imclose(bwG,  strel('disk', clo)); end
    bwG = bwareaopen(bwG, minA);
    bwG_near = bwG;
    if contactDist > 0; bwG_near = imdilate(bwG, strel('disk', contactDist)); end
end

function [bwR, Lr, Sr, st, aPx, m] = classifyRed(Rp, thr, minPx, bwG, bwG_near, o)
% Red objects and their state: 0 free, 1 touching, 2 partial, 3 inside (engulfed).
% "Inside" is decided by o.rule ('ring' | 'centroid' | 'whole'); see settings.
% All three measurements are returned in m for every object regardless of rule.
    % green with enclosed holes filled: an engulfed red cell sits in such a hole
    bwGf = imfill(bwG, 'holes');

    % red: normal threshold everywhere, optionally lower inside (filled) green
    bwR = Rp > thr;
    if o.insideFactor ~= 1
        bwR = bwR | (bwGf & Rp > thr * o.insideFactor);
    end
    if o.fillHoles; bwR = imfill(bwR, 'holes'); end          % one object per cell
    bwR = bwareaopen(bwR, minPx);
    conn = 8;
    if o.splitH > 0                                          % split touching cells
        bwR  = splitTouching(bwR, o.splitH, 1.6 * o.cellAreaPx);
        bwR  = bwareaopen(bwR, minPx);
        conn = 4;                                            % keep watershed cuts separate
    end
    hazeDrop = false(size(bwR));
    if o.refineFrac > 0                                      % cut cells out of attached haze
        bwPre = bwR;
        bwR = refineObjects(bwR, Rp, o, minPx);              % (what splitting could not fix)
        bwR = bwareaopen(bwR, minPx);
        hazeDrop = bwareaopen(imopen(bwPre & ~bwR, strel('disk', 1)), minPx);   % shown blue in QC
    end
    Lr  = bwlabel(bwR, conn);
    props = {'Area', 'Centroid', 'BoundingBox', 'EquivDiameter', 'MajorAxisLength', ...
             'MinorAxisLength', 'MaxIntensity', 'MeanIntensity', 'Solidity'};
    Sr  = regionprops(Lr, Rp, props{:});
    % filters (kept objects are unchanged):
    %  background: brightest pixel not clearly above background (ratio < o.minPeak)
    %  shape:      cell-sized but irregular (solidity < o.minSolidity)
    %  size:       bigger than o.maxAreaPx (unsplit clumps, large background)
    bwDropped = hazeDrop;
    if ~isempty(Sr)
        a    = [Sr.Area]';
        pk   = ([Sr.MaxIntensity]' - o.bg) / max(o.thrMain - o.bg, eps);
        drop = (o.minPeak > 0 & pk < o.minPeak) | ...
               (o.minSolidity > 0 & a >= o.cellMinPx & [Sr.Solidity]' < o.minSolidity) | ...
               (a > o.maxAreaPx);
        if any(drop)
            dl = [false; drop(:)];  bwDropped = bwDropped | dl(Lr + 1);
            bwR(bwDropped) = false;
            Lr = bwlabel(bwR, conn);
            Sr = regionprops(Lr, Rp, props{:});
        end
    end
    n   = numel(Sr);
    st  = zeros(n,1);  aPx = zeros(n,1);
    m = struct('fracOnGreen', zeros(n,1), 'fracInFilled', zeros(n,1), ...
               'centroidIn', false(n,1), 'ringFrac', nan(n,1), 'bwGf', bwGf, ...
               'geomInside', false(n,1), 'brightRatio', zeros(n,1), 'bright', false(n,1), ...
               'bwDropped', bwDropped);
    if n == 0; return; end

    bwGf_test = bwGf;
    if o.tol > 0; bwGf_test = imdilate(bwGf, strel('disk', o.tol)); end

    aPx  = [Sr.Area]';
    lin  = Lr(:) > 0;
    lab  = Lr(lin);
    onPx     = accumarray(lab, double(bwG(lin)),       [n 1]);
    inFPx    = accumarray(lab, double(bwGf(lin)),      [n 1]);
    inFTest  = accumarray(lab, double(bwGf_test(lin)), [n 1]);
    nearPx   = accumarray(lab, double(bwG_near(lin)),  [n 1]);
    m.fracOnGreen  = onPx  ./ aPx;
    m.fracInFilled = inFPx ./ aPx;

    C  = reshape([Sr.Centroid], 2, [])';
    ci = sub2ind(size(bwGf), min(max(round(C(:,2)),1),size(bwGf,1)), min(max(round(C(:,1)),1),size(bwGf,2)));
    m.centroidIn = bwGf(ci);
    m.ringFrac   = ringGreenFraction(Lr, Sr, bwR, bwG, o.ringWidth);

    st(nearPx > 0) = 1;                                   % touching
    switch o.rule
        case 'ring'
            st(onPx > 0 | m.ringFrac >= o.partialFrac) = 2;   % overlaps green or partly surrounded
            st(m.ringFrac >= o.insideFrac)             = 3;   % surrounded by green
        case 'centroid'
            st(inFPx > 0)    = 2;
            st(m.centroidIn) = 3;
        case 'whole'
            st(inFPx > 0)         = 2;
            st(inFTest == aPx)    = 3;
    end

    % brightness: peak red intensity above background, divided by the fixed
    % reference o.thrMain - o.bg (= 4 x noise for the background method)
    m.geomInside  = st == 3;
    m.brightRatio = ([Sr.MaxIntensity]' - o.bg) / max(o.thrMain - o.bg, eps);
    m.bright      = m.brightRatio >= o.brightRatio;
    switch o.engulfMode
        case 'geometry+bright'
            st(m.geomInside & ~m.bright) = 2;            % surrounded but dim -> partial
        case 'bright'
            st(m.geomInside & ~m.bright) = 2;
            st(st >= 1 & m.bright)       = 3;            % bright and in contact with green
    end
end

function bwOut = refineObjects(bw, Rp, o, minPx)
% Objects that are too big or irregular (or all, if o.refineAll) are carved
% into cells using each piece's OWN brightness: the cut level is raised from
% bg + o.refineFrac x (peak - bg) in steps of 0.1 until compact, cell-sized
% cores appear. Those are kept; the rest of the piece (minus a 3-px rim around
% the kept cores) is searched again for dimmer cells. Pieces that never give a
% cell-like core (large irregular haze) or have no clear peak are dropped.
    cc = bwconncomp(bw, 4);                         % 4-conn: keeps watershed cuts apart
    if cc.NumObjects == 0; bwOut = bw; return; end
    S  = regionprops(cc, 'Area', 'Solidity');
    a  = [S.Area]';  so = [S.Solidity]';
    todo = o.refineAll | ~cellLike(a, so, o);
    bwOut = bw;
    [H, W] = size(bw);
    for k = find(todo(:))'
        [rr, cl] = ind2sub([H W], cc.PixelIdxList{k});
        r1 = max(1, min(rr) - 4);  r2 = min(H, max(rr) + 4);
        c1 = max(1, min(cl) - 4);  c2 = min(W, max(cl) + 4);
        obj = false(r2 - r1 + 1, c2 - c1 + 1);
        obj(sub2ind(size(obj), rr - r1 + 1, cl - c1 + 1)) = true;
        keep = carveCells(obj, Rp(r1:r2, c1:c2), o, minPx);
        sub = bwOut(r1:r2, c1:c2);
        sub(obj) = keep(obj);
        bwOut(r1:r2, c1:c2) = sub;
    end
end

function ok = cellLike(a, so, o)
% compact (solidity) and not bigger than ~1.6 cells; small objects always compact enough
    ok = a <= 1.6 * o.cellAreaPx & (o.minSolidity <= 0 | a < o.cellMinPx | so >= o.minSolidity);
end

function keep = carveCells(work, P, o, minPx)
    keep = false(size(work));
    ref  = max(o.thrMain - o.bg, eps);
    se   = strel('disk', 3);
    queue = {work};  it = 0;
    while ~isempty(queue) && it < 40
        w = queue{1};  queue(1) = [];  it = it + 1;
        pc = bwconncomp(w, 8);
        for j = 1:pc.NumObjects
            idx = pc.PixelIdxList{j};
            if numel(idx) < minPx; continue; end
            pk = max(P(idx));
            if (pk - o.bg) / ref < max(o.minPeak, 1); continue; end      % no clear peak
            comp = false(size(w));  comp(idx) = true;
            if o.refineAll == false
                Sc = regionprops(comp, 'Area', 'Solidity');
                if numel(Sc) == 1 && cellLike(Sc.Area, Sc.Solidity, o) && it > 1
                    keep = keep | comp;  continue                         % already a clean cell
                end
            end
            for f = o.refineFrac:0.1:0.81
                core = bwareaopen(comp & P > o.bg + f * (pk - o.bg), minPx);
                cc2  = bwconncomp(core, 8);
                if cc2.NumObjects == 0; break; end
                S2   = regionprops(cc2, 'Area', 'Solidity');
                good = find(cellLike([S2.Area]', [S2.Solidity]', o) & ...
                            ([S2.Area]' >= o.cellMinPx | o.refineAll));
                if ~isempty(good)
                    g = false(size(w));
                    for q = good(:)'; g(cc2.PixelIdxList{q}) = true; end
                    keep = keep | g;
                    rest = comp & ~imdilate(g, se);                        % look for dimmer cells
                    if any(rest(:)); queue{end+1} = rest; end %#ok<AGROW>
                    break
                end
            end
        end
    end
end

function bw2 = splitTouching(bw, h, maxSinglePx)
% Watershed on the distance map: touching round cells are cut at the neck
% between them, where the neck is at least h px narrower than the cells.
% Objects still bigger than maxSinglePx (tight clusters) are split again with
% h/2, h/4 ... (down to 0.5 px) until they are cell-sized or cannot be split.
    bw2 = wsSplit(bw, h);
    hh  = h / 2;
    while hh >= 0.5 && isfinite(maxSinglePx)
        cc  = bwconncomp(bw2, 4);
        big = find(cellfun(@numel, cc.PixelIdxList) > maxSinglePx);
        if isempty(big); break; end
        [H, Wd] = size(bw2);
        for k = big                                   % work in a small window per clump
            [rr, cl] = ind2sub([H Wd], cc.PixelIdxList{k});
            r1 = max(1, min(rr) - 2);  r2 = min(H,  max(rr) + 2);
            c1 = max(1, min(cl) - 2);  c2 = min(Wd, max(cl) + 2);
            obj = false(r2 - r1 + 1, c2 - c1 + 1);
            obj(sub2ind(size(obj), rr - r1 + 1, cl - c1 + 1)) = true;
            sub = bw2(r1:r2, c1:c2);
            sub(obj) = false;
            bw2(r1:r2, c1:c2) = sub | wsSplit(obj, hh);
        end
        hh = hh / 2;
    end
end

function bw2 = wsSplit(bw, h)
    D  = bwdist(~bw);
    mk = imextendedmax(D, h);                 % one marker per cell centre
    Dn = -D;  Dn(~bw) = Inf;
    Dn = imimposemin(Dn, mk);
    L  = watershed(Dn);
    bw2 = bw & (L > 0);
end

function ring = ringGreenFraction(Lr, Sr, bwR, bwG, w)
% For each red object: fraction of the way AROUND it that green is found
% within w px of its edge (0 = no green nearby, 1 = completely surrounded).
% The ring is split into 36 directions (10 deg each) from the object's centre;
% a direction counts as green if any ring pixel in it is green. This way a
% dark gap between the red cell and the green rim does not lower the score.
% Ring pixels belonging to any red object are ignored.
    n = numel(Sr);  ring = nan(n,1);
    if w < 1; return; end
    nBins = 36;
    se = strel('disk', w);
    [H, W] = size(Lr);
    for k = 1:n
        bb = Sr(k).BoundingBox;
        r1 = max(1, floor(bb(2)) - w);  r2 = min(H, ceil(bb(2) + bb(4)) + w);
        c1 = max(1, floor(bb(1)) - w);  c2 = min(W, ceil(bb(1) + bb(3)) + w);
        obj  = Lr(r1:r2, c1:c2) == k;
        band = imdilate(obj, se) & ~bwR(r1:r2, c1:c2);
        [yy, xx] = find(band);
        if isempty(yy); continue; end
        g   = bwG(sub2ind([H W], yy + r1 - 1, xx + c1 - 1));
        ang = atan2(yy + r1 - 1 - Sr(k).Centroid(2), xx + c1 - 1 - Sr(k).Centroid(1));
        bin = min(nBins, floor((ang + pi) / (2*pi) * nBins) + 1);
        hasBand  = accumarray(bin, 1, [nBins 1]) > 0;
        hasGreen = accumarray(bin, double(g), [nBins 1]) > 0;
        ring(k)  = sum(hasGreen & hasBand) / sum(hasBand);
    end
end

function o = outlineMask(mask, w)
% Outline of a mask, w pixels thick, centred on the edge (QC display only).
    o = bwperim(mask);
    r = floor((w - 1) / 2);
    if r > 0; o = imdilate(o, strel('disk', r)); end
end

function rgb = makeOverlay(G, Rd, dLo, dHi, gIdx, rIdx, d, bwG, Lr, st, stateColors)
% Green signal = green, red signal = magenta; white = green mask edge;
% red outlines coloured by state (stateColors rows: free, touching, partial, inside).
% Display: dLo -> black, dHi -> full brightness, then gamma and gain (QC only).
    gN = min(max((G  - dLo(gIdx)) / (dHi(gIdx) - dLo(gIdx)), 0), 1) .^ d.gamma * d.gGain;
    rN = min(max((Rd - dLo(rIdx)) / (dHi(rIdx) - dLo(rIdx)), 0), 1) .^ d.gamma * d.rGain;
    rgb = min(max(cat(3, rN, gN, rN), 0), 1);
    rgb = paintMask(rgb, outlineMask(bwG, d.lineW), [1 1 1]);
    S = stateImage(Lr, st);
    for s = 0:3
        rgb = paintMask(rgb, outlineMask(S == s + 1, d.lineW), stateColors(s+1,:));
    end
end

function ok = insideConfirmed(H, f, xy, P, tNow, isFinal)
% Persistence rule by LOCATION (no cell tracking): starting from an inside
% object at frame f, position xy (um), follow inside objects forwards and
% backwards in time - each step to the nearest inside object within
% P.matchDist of the last position. Up to P.gap missing frames in a row are
% allowed. Confirmed when the run covers >= P.N frames. A shorter run that
% reaches the end of the movie counts only if P.countUnfinished (and isFinal).
    if P.N <= 1; ok = true; return; end
    len = 1;  touchesEnd = false;
    for dirn = [1 -1]
        pos = xy;  u = f;  miss = 0;
        while true
            u = u + dirn;
            if u < 1 || u > tNow
                if dirn == 1 && u > tNow && tNow >= P.nT; touchesEnd = true; end
                break
            end
            h = H{u};  m = [];
            if ~isempty(h)
                ins = h(h(:,3) == 3, 1:2);
                if ~isempty(ins)
                    [dm, k] = min(hypot(ins(:,1) - pos(1), ins(:,2) - pos(2)));
                    if dm <= P.matchDist; m = ins(k,:); end
                end
            end
            if isempty(m)
                miss = miss + 1;
                if miss > P.gap; break; end
            else
                len = len + 1;  pos = m;  miss = 0;
                if len >= P.N; ok = true; return; end
            end
        end
    end
    ok = isFinal && P.countUnfinished && touchesEnd;
end

function st = confirmFrameStatesLoc(q, H, tNow, isFinal, P)
% Final states for the objects of queued frame q (inside -> partial if the
% engulfment does not persist at that place).
    st = q.state;
    for j = find(q.state(:)' == 3)
        if ~insideConfirmed(H, q.t, q.xy(j,:), P, tNow, isFinal); st(j) = 2; end
    end
end

function [RT, R] = finalizeEngulfment(RT, R, rows, nT, H, P)
% Apply the location-based persistence rule to every object, store the raw
% state as StateRaw, recompute this movie's per-frame counts / engulfed area,
% and count NEW engulfments (confirmed engulfed object with none at the same
% place in the previous 1 + P.gap frames).
    RT.StateRaw = RT.State;
    newS = RT.State;
    for i = find(RT.State(:)' == 3)
        if ~insideConfirmed(H, RT.Timepoint(i), [RT.X_um(i) RT.Y_um(i)], P, nT, true)
            newS(i) = 2;
        end
    end
    RT.State = newS;
    codes = 'FTPI';
    RT.StateLabel = string(num2cell(codes(newS + 1)'));
    why = repmat("", height(RT), 1);                      % why contact cells are not engulfed
    p2  = newS == 2;
    why(p2 & RT.StateRaw == 3)                  = "too brief";
    why(p2 & RT.StateRaw ~= 3 & RT.GeomInside)  = "dim";
    why(p2 & RT.StateRaw ~= 3 & ~RT.GeomInside) = "not surrounded";
    RT.WhyNotEngulfed = why;

    a  = RT.Area_um2;  fg = RT.SizeClass == "fragment";
    Cin = cell(1, nT);                                    % confirmed engulfed positions per frame
    for t = 1:nT
        m = RT.Timepoint == t & newS == 3;
        Cin{t} = [RT.X_um(m) RT.Y_um(m)];
    end
    cum = 0;
    for t = 1:nT
        r  = rows(t);
        m  = RT.Timepoint == t;
        s  = newS(m);  aa = a(m);  ff = fg(m);  nR = numel(s);
        R(r).N_Red_Free          = sum(s == 0);
        R(r).N_Red_Touching      = sum(s == 1);
        R(r).N_Red_Partial       = sum(s == 2);
        R(r).N_Red_Inside        = sum(s == 3);
        R(r).N_Red_InContact     = sum(s == 1 | s == 2);
        R(r).Frac_Red_InContact  = sum(s == 1 | s == 2) / max(nR, 1);
        R(r).Frac_Red_Inside     = sum(s == 3) / max(nR, 1);
        R(r).Area_Red_Inside_um2 = sum(aa(s == 3));
        R(r).N_Inside_Cells      = sum(s == 3 & ~ff);
        R(r).N_Inside_Fragments  = sum(s == 3 & ff);
        R(r).MedianArea_Free_um2    = medianOrNaN(aa(s == 0));
        R(r).MedianArea_Contact_um2 = medianOrNaN(aa(s == 1 | s == 2));
        R(r).MedianArea_Inside_um2  = medianOrNaN(aa(s == 3));
        R(r).MeanArea_Inside_um2    = meanOrNaN(aa(s == 3));
        R(r).Engulfed_per_GreenArea_pct = 100 * sum(aa(s == 3)) / max(R(r).Area_Green_Filled_um2, eps);
        % engulfed red per mm2 of GREEN FOOTPRINT (green area with holes filled -
        % the same denominator as Engulfed_per_GreenArea_pct)
        gA = R(r).Area_Green_Filled_um2 / 1e6;                   % mm2
        if gA > 0
            R(r).Engulfed_Objects_per_mm2_Green   = sum(s == 3) / gA;          % cells + fragments
            R(r).Engulfed_Cells_per_mm2_Green     = sum(s == 3 & ~ff) / gA;    % cells only (>= redCellMinArea_um2)
            R(r).Engulfed_Fragments_per_mm2_Green = sum(s == 3 &  ff) / gA;    % fragments only
        else
            [R(r).Engulfed_Objects_per_mm2_Green, R(r).Engulfed_Cells_per_mm2_Green, ...
             R(r).Engulfed_Fragments_per_mm2_Green] = deal(NaN);
        end
        % red objects that are NOT engulfed = free + touching + partial
        R(r).N_Red_FreeOrContact    = sum(s < 3);
        R(r).N_Cells_FreeOrContact  = sum(s < 3 & ~ff);
        R(r).Frac_Red_FreeOrContact = sum(s < 3) / max(nR, 1);
        if t == 1
            R(r).N_Engulfed = NaN;                        % already engulfed before the movie
        else
            prevPts = vertcat(Cin{max(1, t - 1 - P.gap):t - 1});
            cur = Cin{t};  nE = 0;
            for k = 1:size(cur, 1)
                if isempty(prevPts) || min(hypot(prevPts(:,1) - cur(k,1), prevPts(:,2) - cur(k,2))) > P.matchDist
                    nE = nE + 1;
                end
            end
            R(r).N_Engulfed = nE;
            cum = cum + nE;
        end
        R(r).Cum_Engulfed = cum;
    end
end

function T = movieSummary(Rr, filename)
% One row per movie from its per-frame summary rows.
    ins = [Rr.N_Red_Inside];   nE = [Rr.N_Engulfed];   el = [Rr.Elapsed_h];
    i1  = find(nE > 0, 1);
    if isempty(i1); tFirst = NaN; else; tFirst = el(i1); end
    T = table(string(filename), numel(Rr), el(end), ins(1), ins(end), max(ins), ...
        Rr(end).Cum_Engulfed, tFirst, mean([Rr.Frac_Red_Inside]), mean([Rr.Frac_Red_InContact]), ...
        mean([Rr.N_Red]), Rr(1).Engulfed_per_GreenArea_pct, Rr(end).Engulfed_per_GreenArea_pct, ...
        mean([Rr.Contact_Length_um]), ...
        'VariableNames', {'ImageName', 'N_Frames', 'Duration_h', 'Inside_FirstFrame', 'Inside_LastFrame', ...
        'Inside_Max', 'New_Engulfments', 'First_New_Engulfment_h', 'Mean_Frac_Inside', ...
        'Mean_Frac_InContact', 'Mean_N_Red', 'EngulfedArea_pct_First', 'EngulfedArea_pct_Last', ...
        'Mean_Contact_Length_um'});
end

function W = writeQCFrame(q, H, tNow, isFinal, P, W, vw, vwR)
% Write masks / QC / red-only QC for one (delayed) frame with final states.
    st   = confirmFrameStatesLoc(q, H, tNow, isFinal, P);
    S    = stateImage(q.Lr, st);
    imH  = size(q.G, 1);
    nRed = numel(st);
    cnt  = [sum(st==0) sum(st==1) sum(st==2) sum(st==3)];
    if P.saveMasks
        W.green     = putFrame(W.green,     uint8(q.bwG)*255,  P.outputDir, P.baseName, 'green',     q.t, P.mode);
        W.redall    = putFrame(W.redall,    uint8(q.bwR)*255,  P.outputDir, P.baseName, 'redall',    q.t, P.mode);
        W.redinside = putFrame(W.redinside, uint8(S == 4)*255, P.outputDir, P.baseName, 'redinside', q.t, P.mode);
    end
    if P.saveQC
        qc = uint8(makeOverlay(q.G, q.Rd, P.dLo, P.dHi, P.greenIdx, P.redIdx, P.disp, q.bwG, q.Lr, st, P.stateColors) * 255);
        if P.hasText
            qc = insertText(qc, [10 10], sprintf('t%d  %.1f h   free %d  touch %d  partial %d  inside %d', ...
                q.t, q.elapsed_h, cnt), ...
                'FontSize', max(14, round(imH/45)), 'TextColor', 'white', 'BoxColor', 'black', 'BoxOpacity', 0.6);
            qc = insertText(qc, [10 imH - max(14, round(imH/45)) - 18], sprintf(['white = green mask | grey = free | ' ...
                'yellow = touching | orange = partial | cyan = engulfed (inside >= %d frames)'], P.N), ...
                'FontSize', max(12, round(imH/55)), 'TextColor', 'white', 'BoxColor', 'black', 'BoxOpacity', 0.6);
        end
        W.QC = putFrame(W.QC, qc, P.outputDir, P.baseName, 'QC', q.t, P.mode);
        if ~isempty(vw); writeVideo(vw, qc); end
    end
    if P.saveRedQC
        qr = uint8(255 * makeRedOverlay(q.Rd, P.dLo, P.dHi, P.redIdx, P.disp, q.Lr, st, P.stateColorsRed, ...
                                        q.bwG, P.redShowGreen, P.redShowRemoved * q.bwDropped));
        if P.hasText
            fs = max(14, round(imH/45));
            qr = insertText(qr, [10 10], sprintf('RED  t%d  %.1f h   red thr %.4f   free %d  touch %d  partial %d  inside %d', ...
                q.t, q.elapsed_h, q.thr, cnt), ...
                'FontSize', fs, 'TextColor', 'white', 'BoxColor', 'black', 'BoxOpacity', 0.6);
            qr = insertText(qr, [10 imH - fs - 18], sprintf(['magenta = free | yellow = touching | orange = partial | ' ...
                'cyan = engulfed (>= %d frames) | blue = removed   (labels: %s; D = dim < %g, R = ring %% < %g, T = < %d frames)'], ...
                P.N, P.redLabel, P.brightCut, 100 * P.ringCut, P.N), ...
                'FontSize', max(12, round(imH/55)), 'TextColor', 'white', 'BoxColor', 'black', 'BoxOpacity', 0.6);
        else
            qr = drawLabel(qr, 4, 4, sprintf('%d', q.t), [255 255 255], P.labelScale);   % frame number
        end
        % labels next to red cells (pixel font, no toolbox needed)
        for j = 1:nRed
            switch lower(P.redLabel)
                case 'reason'
                    if st(j) ~= 2; continue; end
                    if q.state(j) == 3
                        lb = 'T';                                         % too brief
                    elseif q.geom(j)
                        lb = sprintf('D%.1f', q.bright(j));               % surrounded but dim
                    else
                        lb = sprintf('R%d', round(100 * q.ring(j)));      % not surrounded enough
                    end
                case 'brightness', lb = sprintf('%.1f', q.bright(j));
                otherwise,         continue
            end
            qr = drawLabel(qr, round(q.Cr(j,1)) + 6, round(q.Cr(j,2)) - 3 * P.labelScale, lb, [255 255 0], P.labelScale);
        end
        W.QCred = putFrame(W.QCred, qr, P.outputDir, P.baseName, 'QCred', q.t, P.mode);
        if ~isempty(vwR); writeVideo(vwR, qr); end
    end
end

function S = stateImage(Lr, st)
% Label image -> state image (0 background, state+1 per object) via lookup table.
    lut = uint8([0; st(:) + 1]);
    S = lut(Lr + 1);
end

function ref = brightReference(method, mode, bg, nz, thr)
% Fixed reference level for the brightness ratio: background + 4 x noise for the
% 'background' red threshold (independent of redBgK); otherwise the red threshold.
    if strcmpi(method, 'background') && ~strcmpi(mode, 'manual')
        ref = bg + 4 * nz;
    else
        ref = thr;
    end
end

function rgb = makeRedOverlay(Rd, dLo, dHi, rIdx, d, Lr, st, colors, bwG, showGreen, bwRemoved)
% Red channel only, shown in grey (same display range/gamma as the main QC),
% with red outlines coloured by state; optional dark-green green-mask edge;
% objects removed by the filters outlined in blue.
    r   = min(max((Rd - dLo(rIdx)) / (dHi(rIdx) - dLo(rIdx)), 0), 1) .^ d.gamma * d.rGain;
    r   = min(r, 1);
    rgb = cat(3, r, r, r);
    if showGreen; rgb = paintMask(rgb, outlineMask(bwG, d.lineW), [0 0.6 0]); end
    if any(bwRemoved(:)); rgb = paintMask(rgb, outlineMask(bwRemoved > 0, d.lineW), [0.25 0.45 1]); end
    S = stateImage(Lr, st);
    for s = 0:3
        rgb = paintMask(rgb, outlineMask(S == s + 1, d.lineW), colors(s+1,:));
    end
end

function img = drawLabel(img, x, y, str, col, sc)
% Draw text with a built-in 3x5 pixel font (digits . - % and D R T B I),
% black box behind for contrast. No toolbox needed. (x, y) = top-left corner.
    if isempty(str); return; end
    gw = 3 * sc;  gh = 5 * sc;  sp = sc;
    w  = numel(str) * (gw + sp) + sp;  h = gh + 2 * sp;
    [H, W, ~] = size(img);
    x = min(max(1, x), max(1, W - w));  y = min(max(1, y), max(1, H - h));
    r1 = y;  r2 = min(H, y + h - 1);  c1 = x;  c2 = min(W, x + w - 1);
    img(r1:r2, c1:c2, :) = 0;                                      % background box
    for k = 1:numel(str)
        g = glyph(str(k));
        if isempty(g); continue; end
        g  = kron(g, ones(sc)) > 0;
        rr = y + sp + (0:gh-1);  cc = x + sp + (k-1) * (gw + sp) + (0:gw-1);
        okr = rr >= 1 & rr <= H;  okc = cc >= 1 & cc <= W;
        for ch = 1:size(img, 3)
            blk = img(rr(okr), cc(okc), ch);
            gg  = g(okr, okc);
            blk(gg) = col(min(ch, numel(col)));
            img(rr(okr), cc(okc), ch) = blk;
        end
    end
end

function g = glyph(c)
% 3x5 bitmap (rows top to bottom)
    switch c
        case '0', b = [7 5 5 5 7];   case '1', b = [2 6 2 2 7];
        case '2', b = [7 1 7 4 7];   case '3', b = [7 1 7 1 7];
        case '4', b = [5 5 7 1 1];   case '5', b = [7 4 7 1 7];
        case '6', b = [7 4 7 5 7];   case '7', b = [7 1 1 1 1];
        case '8', b = [7 5 7 5 7];   case '9', b = [7 5 7 1 7];
        case '.', b = [0 0 0 0 2];   case '-', b = [0 0 7 0 0];
        case '%', b = [5 1 2 4 5];
        case 'D', b = [6 5 5 5 6];   case 'R', b = [6 5 6 5 5];
        case 'T', b = [7 2 2 2 2];   case 'B', b = [6 5 6 5 6];
        case 'I', b = [7 2 2 2 7];
        otherwise, g = []; return
    end
    g = logical([bitand(b(:), 4) bitand(b(:), 2) bitand(b(:), 1)] > 0);
end

function outPath = safeWriteTable(T, path)
% writetable, but if the file can't be overwritten (e.g. it is open in Excel)
% save it under a time-stamped name instead of stopping the run.
    outPath = path;
    try
        writetable(T, path);
    catch err
        [d, n, e] = fileparts(path);
        outPath = fullfile(d, sprintf('%s_%s%s', n, datestr(now, 'yyyymmdd_HHMMSS'), e));
        warning('Could not write %s (%s) - is it open in Excel? Saved as %s instead.', path, err.message, outPath);
        writetable(T, outPath);
    end
end

function saveFig(fig, path)
% Save a figure as PNG without MATLAB's OpenGL/Java print path, which can crash
% on some systems ("setupPrint() not called"). Tries exportgraphics, then
% print with the painters renderer, then a screen grab. If everything fails it
% only WARNS, so a plotting problem never stops the analysis.
    msg = '';
    try
        drawnow;
        set(fig, 'Renderer', 'painters');
        if ~isempty(which('exportgraphics'))
            exportgraphics(fig, path, 'Resolution', 150);
            return
        end
    catch err
        msg = err.message;
    end
    try
        print(fig, path, '-dpng', '-painters', '-r150');
        return
    catch err
        msg = err.message;
    end
    try
        fr = getframe(fig);
        imwrite(fr.cdata, path);
        return
    catch err
        msg = err.message;
    end
    warning('Could not save figure %s (%s). The analysis continues.', path, msg);
end

function rgb = paintMask(rgb, mask, col)
    for ch = 1:3
        tmp = rgb(:,:,ch);  tmp(mask) = col(ch);  rgb(:,:,ch) = tmp;
    end
end

function w = stackInit(path, estBytes)
% Writer for one time-ordered multi-page TIF. Uses MATLAB's Tiff object kept
% open (fast); BigTIFF if the stack may pass 4 GB. Falls back to imwrite.
    w = struct('path', path, 'tif', [], 'n', 0, 'useTiff', exist('Tiff', 'class') == 8, ...
               'mode', 'w');
    if estBytes > 3.8e9; w.mode = 'w8'; end
end

function w = putFrame(w, img, outputDir, baseName, tag, t, mode)
% 'stack': next page of the stack; 'separate': one TIF per timepoint.
    if ~strcmpi(mode, 'stack')
        imwrite(img, fullfile(outputDir, sprintf('%s_%s_t%03d.tif', baseName, tag, t)));
        return
    end
    if w.useTiff
        try
            if isempty(w.tif)
                w.tif = Tiff(w.path, w.mode);
            else
                w.tif.writeDirectory();
            end
            tg.ImageLength         = size(img, 1);
            tg.ImageWidth          = size(img, 2);
            tg.BitsPerSample       = 8;
            tg.SamplesPerPixel     = size(img, 3);
            tg.SampleFormat        = Tiff.SampleFormat.UInt;
            tg.PlanarConfiguration = Tiff.PlanarConfiguration.Chunky;
            tg.Compression         = Tiff.Compression.None;
            tg.RowsPerStrip        = 64;
            if size(img, 3) == 3
                tg.Photometric = Tiff.Photometric.RGB;
            else
                tg.Photometric = Tiff.Photometric.MinIsBlack;
            end
            w.tif.setTag(tg);
            w.tif.write(img);
            w.n = w.n + 1;
            return
        catch err
            warning('Fast TIF writing failed (%s); using imwrite for %s.', err.message, w.path);
            try; if ~isempty(w.tif); w.tif.close(); end; catch; end
            w.tif = [];  w.useTiff = false;
        end
    end
    imwrite(img, w.path, 'WriteMode', 'append');
    w.n = w.n + 1;
end

function w = stackClose(w)
    if ~isempty(w.tif)
        try; w.tif.close(); catch; end
        w.tif = [];
    end
end

function px = getPixelSize(info1, override)
% Pixel size in um/px. imfinfo reports ResolutionUnit as text.
    if ~isempty(override)
        px = override;
        fprintf('  Pixel size: %.4f um/px (manual override)\n', px);
        return
    end
    try
        xRes = info1.XResolution;
        ru   = info1.ResolutionUnit;
        if isnumeric(ru)                     % TIFF codes: 1 none, 2 inch, 3 cm
            names = {'None','Inch','Centimeter'};
            ru = names{min(max(ru,1),3)};
        end
        switch lower(ru)
            case 'inch',       px = 25400 / xRes;
            case 'centimeter', px = 10000 / xRes;
            otherwise,         px = 1 / xRes;   % ImageJ: pixels per unit (usually micron)
        end
        fprintf('  Pixel size: %.4f um/px (from metadata, unit "%s")\n', px, ru);
        if px > 5 || px < 0.02
            warning(['Pixel size %.4f um/px looks implausible - metadata is probably ' ...
                     'a default (e.g. 72 dpi). Set pixelSize_um_override.'], px);
        end
    catch
        px = 1;
        warning('Could not read pixel size, using 1 um/px. Set pixelSize_um_override.');
    end
end

function plotSizes(A, baseName, outputDir, minArea, cellArea)
% Size distribution of every red object (all frames), all vs fully inside,
% with the size cutoffs marked; and median size over time by state.
    fig = figure('Name', [baseName ' red sizes'], 'Color', 'w', 'Renderer', 'painters', 'Position', [100 100 1100 450]);
    a = A.Area_um2;
    subplot(1,2,1);
    if ~isempty(a)
        edges = logspace(log10(max(min(a), eps) * 0.9), log10(max(a) * 1.1), 40);
        histogram(a, edges, 'FaceColor', [0.6 0.6 0.6]); hold on;
        histogram(a(A.State == 3), edges, 'FaceColor', [0 0.75 0.75]);
        set(gca, 'XScale', 'log');
        yl = ylim;
        plot([minArea minArea], yl, 'k--', 'LineWidth', 1.2);
        plot([cellArea cellArea], yl, 'r--', 'LineWidth', 1.2);
        legend('all red objects', 'fully inside green', sprintf('noise cutoff %g', minArea), ...
            sprintf('fragment / cell %g', cellArea), 'Location', 'best');
    end
    xlabel('red object area (\mum^2, log scale)'); ylabel('objects (all frames)');
    title('Red object sizes'); grid on;

    subplot(1,2,2); hold on;
    tps = unique(A.Timepoint);
    grp = {A.State == 0, A.State == 1 | A.State == 2, A.State == 3};
    cols = [0.6 0.6 0.6; 1 0.5 0; 0 0.75 0.75];
    for g = 1:3
        med = arrayfun(@(t) medianOrNaN(a(grp{g} & A.Timepoint == t)), tps);
        el  = arrayfun(@(t) A.Elapsed_h(find(A.Timepoint == t, 1)), tps);
        plot(el, med, '-o', 'Color', cols(g,:), 'MarkerSize', 3, 'LineWidth', 1.2);
    end
    xlabel('Elapsed (h)'); ylabel('median area (\mum^2)');
    legend('free', 'in contact', 'fully inside', 'Location', 'best');
    title('Red object size over time'); grid on;
    saveFig(fig, fullfile(outputDir, sprintf('%s_red_sizes.png', baseName)));
end

function plotBrightness(A, baseName, outputDir, cutoff)
% Brightness ratio (peak red above background / reference) of red objects surrounded
% by green vs the rest, with the engulfBrightRatio cut-off; and over time.
% If engulfed cells get brighter, the 'surrounded' histogram should have a
% bright group to the right - put the cut-off in the gap.
    fig = figure('Name', [baseName ' red brightness'], 'Color', 'w', 'Renderer', 'painters', 'Position', [100 100 1100 450]);
    b = A.BrightRatio;  gi = A.GeomInside == 1;
    subplot(1,2,1);
    ok = b > 0;
    if any(ok)
        edges = logspace(log10(min(b(ok)) * 0.9), log10(max(b(ok)) * 1.1), 40);
        histogram(b(ok & ~gi), edges, 'FaceColor', [0.6 0.6 0.6]); hold on;
        histogram(b(ok & gi),  edges, 'FaceColor', [0 0.75 0.75]);
        set(gca, 'XScale', 'log');
        yl = ylim;  plot([cutoff cutoff], yl, 'r--', 'LineWidth', 1.4);
        legend('not surrounded by green', 'surrounded by green', sprintf('engulfBrightRatio = %g', cutoff), 'Location', 'best');
    end
    xlabel('brightness ratio: peak red above bg / (4 x noise)  (log scale)'); ylabel('objects (all frames)');
    title('Red brightness'); grid on;

    subplot(1,2,2); hold on;
    tps = unique(A.Timepoint);
    el  = arrayfun(@(t) A.Elapsed_h(find(A.Timepoint == t, 1)), tps);
    grp = {A.State == 0, A.State == 1 | A.State == 2, gi, A.State == 3};
    cols = [0.6 0.6 0.6; 1 0.5 0; 0 0.45 0.45; 0 0.75 0.75];
    sty  = {'-o', '-o', '--', '-s'};
    for g = 1:4
        med = arrayfun(@(t) medianOrNaN(b(grp{g} & A.Timepoint == t)), tps);
        plot(el, med, sty{g}, 'Color', cols(g,:), 'MarkerSize', 3, 'LineWidth', 1.2);
    end
    plot(el([1 end]), [cutoff cutoff], 'r--');
    xlabel('Elapsed (h)'); ylabel('median brightness ratio');
    legend('free', 'in contact', 'surrounded (geometry)', 'counted inside', 'cut-off', 'Location', 'best');
    title('Red brightness over time'); grid on;
    saveFig(fig, fullfile(outputDir, sprintf('%s_red_brightness.png', baseName)));
end

function v = firstTime(el, mask)
    i = find(mask, 1); if isempty(i); v = NaN; else; v = el(i); end
end
function v = meanOrNaN(x)
    x = x(~isnan(x)); if isempty(x); v = NaN; else; v = mean(x); end
end
function v = medianOrNaN(x)
    x = x(~isnan(x)); if isempty(x); v = NaN; else; v = median(x); end
end
function v = maxOrNaN(x)
    if isempty(x); v = NaN; else; v = max(x); end
end
