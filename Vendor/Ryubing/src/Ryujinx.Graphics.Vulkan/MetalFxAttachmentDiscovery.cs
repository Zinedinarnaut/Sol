using System;
using System.Collections.Generic;
using System.Runtime.CompilerServices;
using Ryujinx.Graphics.GAL;
using Format = Ryujinx.Graphics.GAL.Format;

namespace Ryujinx.Graphics.Vulkan
{
    /// <summary>
    /// Passively identifies renderer-owned scene color, depth, and motion-vector
    /// attachment families. Results are diagnostic only: candidates never enter
    /// the MetalFX frame contract until a later, explicit provider milestone.
    /// </summary>
    internal sealed class MetalFxAttachmentDiscovery
    {
        private const int MaxTrackedTextures = 256;
        private const int MaxTrackedPasses = 512;
        private const int MaxDependencyDepth = 4;
        private const ulong ReportIntervalFrames = 600;
        private const ulong LabelChangeReportSpacingFrames = 120;

        private sealed class ReferenceComparer<T> : IEqualityComparer<T> where T : class
        {
            public static readonly ReferenceComparer<T> Instance = new();

            public bool Equals(T x, T y)
            {
                return ReferenceEquals(x, y);
            }

            public int GetHashCode(T value)
            {
                return RuntimeHelpers.GetHashCode(value);
            }
        }

        private sealed class TextureObservation
        {
            public TextureStorage Storage;
            public TextureView View;
            public Format Format;
            public int Width;
            public int Height;
            public int ColorPasses;
            public int DepthPasses;
            public int CopyWrites;
            public int SamplePasses;
            public int FirstWritePass = int.MaxValue;
            public int LastWritePass;
            public int LastSamplePass;
            public uint ColorSlots;
        }

        private sealed class Candidate
        {
            public TextureObservation Texture;
            public int Score;
            public int RunnerMargin = 100;
            public int PairPasses;
            public string Evidence;
            public bool LinkedToPresented;
        }

        private readonly Dictionary<TextureStorage, TextureObservation> _textures =
            new(ReferenceComparer<TextureStorage>.Instance);
        private readonly Dictionary<TextureStorage, Dictionary<TextureStorage, int>> _inputsByOutput =
            new(ReferenceComparer<TextureStorage>.Instance);
        private readonly Dictionary<TextureStorage, Dictionary<TextureStorage, int>> _depthByColor =
            new(ReferenceComparer<TextureStorage>.Instance);
        private readonly Dictionary<TextureStorage, Dictionary<TextureStorage, int>> _mrtByColor =
            new(ReferenceComparer<TextureStorage>.Instance);
        private readonly HashSet<TextureStorage> _readScratch =
            new(ReferenceComparer<TextureStorage>.Instance);
        private readonly List<TextureObservation> _colorScratch = [];
        private readonly Dictionary<TextureStorage, int> _dependencyDistances =
            new(ReferenceComparer<TextureStorage>.Instance);
        private readonly Queue<TextureStorage> _dependencyQueue = new();

        private ulong _frameId;
        private int _passCount;
        private bool _truncated;

        private string _previousSceneSignature = string.Empty;
        private string _previousDepthSignature = string.Empty;
        private string _previousMotionSignature = string.Empty;
        private int _sceneSightings;
        private int _depthSightings;
        private int _motionSightings;
        private int _sceneMissedFrames;
        private int _depthMissedFrames;
        private int _motionMissedFrames;

        private string _lastPublishedState = string.Empty;
        private ulong _lastPublishedFrame;
        private string _providerSceneSignature = string.Empty;
        private string _lastProviderState = string.Empty;
        private int _providerGeneration = 1;

        internal void RecordRenderPass(
            FramebufferParams framebuffer,
            DescriptorSetUpdater descriptorSetUpdater)
        {
            if (!MetalFxPresentation.IsAttachmentDiscoveryEnabled ||
                framebuffer == null ||
                _passCount >= MaxTrackedPasses)
            {
                _truncated |= _passCount >= MaxTrackedPasses;
                return;
            }

            _passCount++;
            _colorScratch.Clear();

            for (int index = 0; index <= framebuffer.MaxColorAttachmentIndex; index++)
            {
                TextureView view = framebuffer.GetColorView(index);
                TextureObservation color = Observe(view);
                if (color == null)
                {
                    continue;
                }

                color.ColorPasses++;
                color.FirstWritePass = Math.Min(color.FirstWritePass, _passCount);
                color.LastWritePass = _passCount;
                color.ColorSlots |= 1u << Math.Min(index, 31);
                _colorScratch.Add(color);
            }

            if (_colorScratch.Count == 0)
            {
                return;
            }

            _readScratch.Clear();
            descriptorSetUpdater.CollectBoundTextureStorages(_readScratch);

            foreach (TextureStorage readStorage in _readScratch)
            {
                TextureObservation read = Observe(readStorage);
                if (read == null)
                {
                    continue;
                }

                read.SamplePasses++;
                read.LastSamplePass = _passCount;

                foreach (TextureObservation color in _colorScratch)
                {
                    if (!ReferenceEquals(readStorage, color.Storage))
                    {
                        IncrementPair(_inputsByOutput, color.Storage, readStorage);
                    }
                }
            }

            TextureObservation depth = Observe(framebuffer.GetDepthStencilView());
            if (depth != null)
            {
                depth.DepthPasses++;
                depth.FirstWritePass = Math.Min(depth.FirstWritePass, _passCount);
                depth.LastWritePass = _passCount;

                foreach (TextureObservation color in _colorScratch)
                {
                    IncrementPair(_depthByColor, color.Storage, depth.Storage);
                }
            }

            for (int first = 0; first < _colorScratch.Count; first++)
            {
                for (int second = first + 1; second < _colorScratch.Count; second++)
                {
                    TextureStorage firstStorage = _colorScratch[first].Storage;
                    TextureStorage secondStorage = _colorScratch[second].Storage;
                    IncrementPair(_mrtByColor, firstStorage, secondStorage);
                    IncrementPair(_mrtByColor, secondStorage, firstStorage);
                }
            }
        }

        internal void CompleteFrame(TextureView presented)
        {
            if (!MetalFxPresentation.IsAttachmentDiscoveryEnabled)
            {
                ResetFrame();
                return;
            }

            _frameId++;

            TextureObservation presentedObservation = Observe(presented);
            Candidate scene = FindSceneCandidate(presentedObservation);
            Candidate depth = FindDepthCandidate(scene);
            Candidate motion = FindMotionCandidate(scene);
            string incomingSceneSignature = CandidateSignature(scene);
            bool sceneCut =
                !string.IsNullOrEmpty(_providerSceneSignature) &&
                !string.IsNullOrEmpty(incomingSceneSignature) &&
                !string.Equals(
                    _providerSceneSignature,
                    incomingSceneSignature,
                    StringComparison.Ordinal);

            if (sceneCut)
            {
                _providerGeneration++;
            }

            int sceneSightings = UpdateStability(
                ref _previousSceneSignature,
                ref _sceneSightings,
                ref _sceneMissedFrames,
                CandidateSignature(scene));
            int depthSightings = UpdateStability(
                ref _previousDepthSignature,
                ref _depthSightings,
                ref _depthMissedFrames,
                CandidateSignature(depth));
            int motionSightings = UpdateStability(
                ref _previousMotionSignature,
                ref _motionSightings,
                ref _motionMissedFrames,
                CandidateSignature(motion));

            string sceneLabel = Classify(scene, sceneSightings);
            string depthLabel = Classify(depth, depthSightings);
            string motionLabel = Classify(motion, motionSightings);
            bool sceneReady = sceneLabel == "stable" && scene?.LinkedToPresented == true;
            bool depthReady =
                sceneReady &&
                depthLabel == "stable" &&
                depth?.LinkedToPresented == true &&
                HasExactDimensions(depth.Texture, scene.Texture);
            bool motionReady =
                sceneReady &&
                motionLabel == "stable" &&
                motion?.LinkedToPresented == true &&
                HasExactDimensions(motion.Texture, scene.Texture);

            if (sceneReady)
            {
                _providerSceneSignature = incomingSceneSignature;
            }

            bool rawExportReady =
                sceneReady &&
                depthReady &&
                motionReady &&
                scene.Texture.View.TryExportMetalTexture(out nint sceneMetalTexture) &&
                depth.Texture.View.TryExportMetalTexture(out nint depthMetalTexture) &&
                motion.Texture.View.TryExportMetalTexture(out nint motionMetalTexture) &&
                sceneMetalTexture != 0 &&
                depthMetalTexture != 0 &&
                motionMetalTexture != 0;

            // Raw MoltenVK Metal objects are only topology proof. The provider
            // still must canonicalize depth, prove motion direction/units, and
            // align every attachment before Temporal can consume them.
            const bool canonicalExportReady = false;
            string providerState =
                $"{_providerGeneration}:{sceneReady}:{depthReady}:{motionReady}:" +
                $"{rawExportReady}:{canonicalExportReady}:{sceneCut}:{incomingSceneSignature}:" +
                $"{CandidateSignature(depth)}:{CandidateSignature(motion)}";

            if (!string.Equals(providerState, _lastProviderState, StringComparison.Ordinal))
            {
                MetalFxProviderReadiness readiness = new(
                    _frameId,
                    _providerGeneration,
                    sceneReady,
                    depthReady,
                    motionReady,
                    rawExportReady,
                    canonicalExportReady,
                    sceneCut,
                    sceneLabel,
                    depthLabel,
                    motionLabel,
                    depth?.Texture.Format.ToString() ?? "Unknown",
                    motion?.Texture.Format.ToString() ?? "Unknown",
                    scene?.Texture.Width ?? 0,
                    scene?.Texture.Height ?? 0);
                MetalFxPresentation.ReportProviderReadiness(in readiness);
                _lastProviderState = providerState;
            }

            string state =
                $"{sceneLabel}:{_previousSceneSignature}|" +
                $"{depthLabel}:{_previousDepthSignature}:{depth?.LinkedToPresented}|" +
                $"{motionLabel}:{_previousMotionSignature}:{motion?.LinkedToPresented}";

            bool labelChanged = !string.Equals(state, _lastPublishedState, StringComparison.Ordinal);
            bool shouldPublish =
                _frameId == 1 ||
                _frameId - _lastPublishedFrame >= ReportIntervalFrames ||
                (labelChanged && _frameId - _lastPublishedFrame >= LabelChangeReportSpacingFrames);

            if (shouldPublish)
            {
                string truncation = _truncated ? ", scan-bounded" : string.Empty;
                string message =
                    $"DLSM attachment labels f{_frameId}: " +
                    $"scene={DescribeCandidate(scene, sceneLabel, sceneSightings)}; " +
                    $"depth={DescribeCandidate(depth, depthLabel, depthSightings)}; " +
                    $"motion={DescribeCandidate(motion, motionLabel, motionSightings)} " +
                    $"(passes={_passCount}, textures={_textures.Count}{truncation}). " +
                    $"raw-export={(rawExportReady ? "ready" : "waiting")}; " +
                    "Native attachment use and Frame Generation remain locked until canonical semantics pass; Sol Temporal can use reconstructed motion meanwhile.";

                MetalFxPresentation.ReportAttachmentLabels(message);
                _lastPublishedState = state;
                _lastPublishedFrame = _frameId;
            }

            ResetFrame();
        }

        internal void RecordCopy(TextureView source, TextureView destination)
        {
            if (!MetalFxPresentation.IsAttachmentDiscoveryEnabled ||
                source?.Storage == null ||
                destination?.Storage == null ||
                ReferenceEquals(source.Storage, destination.Storage) ||
                _passCount >= MaxTrackedPasses)
            {
                _truncated |= _passCount >= MaxTrackedPasses;
                return;
            }

            _passCount++;

            TextureObservation sourceObservation = Observe(source);
            TextureObservation destinationObservation = Observe(destination);
            if (sourceObservation == null || destinationObservation == null)
            {
                return;
            }

            sourceObservation.SamplePasses++;
            sourceObservation.LastSamplePass = _passCount;
            destinationObservation.CopyWrites++;
            destinationObservation.FirstWritePass = Math.Min(
                destinationObservation.FirstWritePass,
                _passCount);
            destinationObservation.LastWritePass = _passCount;

            IncrementPair(
                _inputsByOutput,
                destinationObservation.Storage,
                sourceObservation.Storage);
        }

        private Candidate FindSceneCandidate(TextureObservation presented)
        {
            if (presented == null)
            {
                return null;
            }

            _dependencyDistances.Clear();
            _dependencyQueue.Clear();
            _dependencyDistances[presented.Storage] = 0;
            _dependencyQueue.Enqueue(presented.Storage);

            while (_dependencyQueue.Count > 0)
            {
                TextureStorage output = _dependencyQueue.Dequeue();
                int distance = _dependencyDistances[output];
                if (distance >= MaxDependencyDepth ||
                    !_inputsByOutput.TryGetValue(output, out Dictionary<TextureStorage, int> inputs))
                {
                    continue;
                }

                foreach (TextureStorage input in inputs.Keys)
                {
                    if (!_dependencyDistances.ContainsKey(input))
                    {
                        _dependencyDistances[input] = distance + 1;
                        _dependencyQueue.Enqueue(input);
                    }
                }
            }

            Candidate best = null;
            Candidate runnerUp = null;

            foreach ((TextureStorage storage, int distance) in _dependencyDistances)
            {
                if (!_textures.TryGetValue(storage, out TextureObservation observation) ||
                    observation.ColorPasses == 0)
                {
                    continue;
                }

                int score = Math.Max(4, 35 - distance * 5);
                score += DimensionScore(observation, presented);
                score += Math.Min(10, observation.ColorPasses);

                if (_depthByColor.ContainsKey(storage))
                {
                    score += 35;
                }

                if (observation.LastSamplePass > observation.FirstWritePass)
                {
                    score += 5;
                }

                Candidate candidate = new()
                {
                    Texture = observation,
                    Score = Math.Min(100, score),
                    Evidence = distance == 0 ? "presented" : $"present-chain-{distance}",
                    LinkedToPresented = true,
                };
                InsertCandidate(candidate, ref best, ref runnerUp);
            }

            if (best == null)
            {
                foreach (TextureObservation observation in _textures.Values)
                {
                    if (observation.ColorPasses == 0)
                    {
                        continue;
                    }

                    int score =
                        DimensionScore(observation, presented) +
                        Math.Min(10, observation.ColorPasses) +
                        (observation.LastSamplePass > observation.FirstWritePass ? 5 : 0) +
                        (_depthByColor.ContainsKey(observation.Storage) ? 25 : 0);

                    if (score < 35)
                    {
                        continue;
                    }

                    Candidate candidate = new()
                    {
                        Texture = observation,
                        Score = Math.Min(69, score),
                        Evidence = "unlinked-present",
                        LinkedToPresented = false,
                    };
                    InsertCandidate(candidate, ref best, ref runnerUp);
                }
            }

            ApplyRunnerMargin(best, runnerUp);
            return best;
        }

        private Candidate FindDepthCandidate(Candidate scene)
        {
            if (scene == null ||
                !_depthByColor.TryGetValue(
                    scene.Texture.Storage,
                    out Dictionary<TextureStorage, int> pairedDepth))
            {
                return null;
            }

            Candidate best = null;
            Candidate runnerUp = null;

            foreach ((TextureStorage storage, int pairPasses) in pairedDepth)
            {
                if (!_textures.TryGetValue(storage, out TextureObservation observation) ||
                    !observation.Format.IsDepthOrStencil)
                {
                    continue;
                }

                double pairRatio = Math.Min(1d, pairPasses / (double)Math.Max(1, scene.Texture.ColorPasses));
                bool exactSize = HasExactDimensions(observation, scene.Texture);
                bool sampledLater = observation.LastSamplePass > observation.FirstWritePass;
                int score =
                    25 +
                    (int)Math.Round(pairRatio * 35d) +
                    (exactSize ? 20 : SameAspect(observation, scene.Texture) ? 10 : 0) +
                    (sampledLater ? 5 : 0) +
                    (pairPasses >= 3 ? 10 : 0);
                if (!scene.LinkedToPresented)
                {
                    score = Math.Min(69, score);
                }

                Candidate candidate = new()
                {
                    Texture = observation,
                    Score = Math.Min(100, score),
                    PairPasses = pairPasses,
                    Evidence =
                        $"paired-{pairRatio:P0}," +
                        $"{(exactSize ? "exact-size" : "scaled-size")}," +
                        $"{(sampledLater ? "read-later" : "not-read-later")}" +
                        $"{(scene.LinkedToPresented ? string.Empty : ",unlinked-present")}",
                    LinkedToPresented = scene.LinkedToPresented,
                };
                InsertCandidate(candidate, ref best, ref runnerUp);
            }

            ApplyRunnerMargin(best, runnerUp);
            return best;
        }

        private Candidate FindMotionCandidate(Candidate scene)
        {
            if (scene == null ||
                !_mrtByColor.TryGetValue(
                    scene.Texture.Storage,
                    out Dictionary<TextureStorage, int> pairedColors))
            {
                return null;
            }

            Candidate best = null;
            Candidate runnerUp = null;

            foreach ((TextureStorage storage, int pairPasses) in pairedColors)
            {
                if (!_textures.TryGetValue(storage, out TextureObservation observation))
                {
                    continue;
                }

                int formatScore = MotionFormatScore(observation.Format);
                if (formatScore == 0)
                {
                    continue;
                }

                double pairRatio = Math.Min(1d, pairPasses / (double)Math.Max(1, scene.Texture.ColorPasses));
                bool exactSize = HasExactDimensions(observation, scene.Texture);
                bool sampledLater = observation.LastSamplePass > observation.FirstWritePass;
                bool secondarySlot = (observation.ColorSlots & ~1u) != 0;
                int score =
                    formatScore +
                    (int)Math.Round(pairRatio * 30d) +
                    (exactSize ? 20 : SameAspect(observation, scene.Texture) ? 10 : 0) +
                    (sampledLater ? 10 : 0) +
                    (secondarySlot ? 5 : 0) +
                    (pairPasses >= 3 ? 5 : 0);
                if (!scene.LinkedToPresented)
                {
                    score = Math.Min(69, score);
                }

                Candidate candidate = new()
                {
                    Texture = observation,
                    Score = Math.Min(100, score),
                    PairPasses = pairPasses,
                    Evidence =
                        $"mrt-paired-{pairRatio:P0}," +
                        $"{(exactSize ? "exact-size" : "scaled-size")}," +
                        $"{(sampledLater ? "read-later" : "not-read-later")}," +
                        $"slots-0x{observation.ColorSlots:x}" +
                        $"{(scene.LinkedToPresented ? string.Empty : ",unlinked-present")}",
                    LinkedToPresented = scene.LinkedToPresented,
                };
                InsertCandidate(candidate, ref best, ref runnerUp);
            }

            ApplyRunnerMargin(best, runnerUp);
            return best;
        }

        private TextureObservation Observe(TextureView view)
        {
            return view?.Storage == null ? null : Observe(view.Storage, view);
        }

        private TextureObservation Observe(TextureStorage storage)
        {
            return storage == null ? null : Observe(storage, null);
        }

        private TextureObservation Observe(TextureStorage storage, TextureView view)
        {
            if (_textures.TryGetValue(storage, out TextureObservation observation))
            {
                if (view != null)
                {
                    observation.View = view;
                    observation.Format = view.Info.Format;
                    observation.Width = view.Width;
                    observation.Height = view.Height;
                }

                return observation;
            }

            if (_textures.Count >= MaxTrackedTextures)
            {
                _truncated = true;
                return null;
            }

            observation = new TextureObservation
            {
                Storage = storage,
                View = view,
                Format = view?.Info.Format ?? storage.Info.Format,
                Width = view?.Width ?? storage.Info.Width,
                Height = view?.Height ?? storage.Info.Height,
            };
            _textures.Add(storage, observation);
            return observation;
        }

        private static void IncrementPair(
            Dictionary<TextureStorage, Dictionary<TextureStorage, int>> pairs,
            TextureStorage owner,
            TextureStorage candidate)
        {
            if (!pairs.TryGetValue(owner, out Dictionary<TextureStorage, int> candidateCounts))
            {
                candidateCounts = new(ReferenceComparer<TextureStorage>.Instance);
                pairs.Add(owner, candidateCounts);
            }

            candidateCounts.TryGetValue(candidate, out int count);
            candidateCounts[candidate] = count + 1;
        }

        private static void InsertCandidate(
            Candidate candidate,
            ref Candidate best,
            ref Candidate runnerUp)
        {
            if (best == null || candidate.Score > best.Score)
            {
                runnerUp = best;
                best = candidate;
            }
            else if (runnerUp == null || candidate.Score > runnerUp.Score)
            {
                runnerUp = candidate;
            }
        }

        private static void ApplyRunnerMargin(Candidate best, Candidate runnerUp)
        {
            if (best == null)
            {
                return;
            }

            best.RunnerMargin = runnerUp == null ? 100 : best.Score - runnerUp.Score;
            if (best.RunnerMargin < 10)
            {
                best.Score = Math.Max(0, best.Score - 15);
                best.Evidence += ",ambiguous";
            }
        }

        private static int DimensionScore(TextureObservation candidate, TextureObservation reference)
        {
            if (HasExactDimensions(candidate, reference))
            {
                return 20;
            }

            return SameAspect(candidate, reference) ? 10 : 0;
        }

        private static bool HasExactDimensions(TextureObservation first, TextureObservation second)
        {
            return first.Width == second.Width && first.Height == second.Height;
        }

        private static bool SameAspect(TextureObservation first, TextureObservation second)
        {
            if (first.Width <= 0 || first.Height <= 0 || second.Width <= 0 || second.Height <= 0)
            {
                return false;
            }

            double firstAspect = first.Width / (double)first.Height;
            double secondAspect = second.Width / (double)second.Height;
            return Math.Abs(firstAspect - secondAspect) <= secondAspect * 0.01d;
        }

        private static int MotionFormatScore(Format format)
        {
            return format switch
            {
                Format.R16G16Float or Format.R32G32Float => 35,
                Format.R16G16Snorm or Format.R16G16Unorm => 24,
                Format.R16G16B16A16Float or Format.R32G32B32A32Float => 16,
                _ => 0,
            };
        }

        private static int UpdateStability(
            ref string previousSignature,
            ref int sightings,
            ref int missedFrames,
            string currentSignature)
        {
            if (string.IsNullOrEmpty(currentSignature))
            {
                missedFrames++;
                if (missedFrames > 120)
                {
                    previousSignature = string.Empty;
                    sightings = 0;
                    missedFrames = 0;
                }

                return sightings;
            }

            if (string.Equals(previousSignature, currentSignature, StringComparison.Ordinal))
            {
                sightings++;
            }
            else
            {
                previousSignature = currentSignature;
                sightings = 1;
            }

            missedFrames = 0;
            return sightings;
        }

        private static string Classify(Candidate candidate, int sightings)
        {
            if (candidate == null || candidate.Score < 45)
            {
                return "unresolved";
            }

            if (candidate.Score >= 85 && sightings >= 90 && candidate.RunnerMargin >= 10)
            {
                return "stable";
            }

            if (candidate.Score >= 70 && sightings >= 30 && candidate.RunnerMargin >= 8)
            {
                return "likely";
            }

            return "candidate";
        }

        private static string DescribeCandidate(
            Candidate candidate,
            string label,
            int sightings)
        {
            if (candidate == null || label == "unresolved")
            {
                return "unresolved";
            }

            return
                $"{label}#{TextureId(candidate.Texture)} " +
                $"{candidate.Texture.Format} {candidate.Texture.Width}x{candidate.Texture.Height} " +
                $"{candidate.Score}% seen={sightings}f {candidate.Evidence}";
        }

        private static string CandidateSignature(Candidate candidate)
        {
            if (candidate == null)
            {
                return string.Empty;
            }

            TextureObservation texture = candidate.Texture;
            return $"{texture.Format}:{texture.Width}x{texture.Height}:slots{texture.ColorSlots:x}";
        }

        private static string TextureId(TextureObservation observation)
        {
            return RuntimeHelpers.GetHashCode(observation.Storage).ToString("x8");
        }

        private void ResetFrame()
        {
            _textures.Clear();
            _inputsByOutput.Clear();
            _depthByColor.Clear();
            _mrtByColor.Clear();
            _readScratch.Clear();
            _colorScratch.Clear();
            _dependencyDistances.Clear();
            _dependencyQueue.Clear();
            _passCount = 0;
            _truncated = false;
        }
    }
}
