def exact_keys($expected): (keys | sort) == ($expected | sort);
def finite_number: type == "number" and isfinite;
def nonnegative_number: finite_number and . >= 0;
def integer: finite_number and floor == .;
def nonnegative_integer: integer and . >= 0;
def steps:
    type == "object" and
    exact_keys(["voxelSteps", "sdfSteps", "gaussianSamples"]) and
    (.voxelSteps | nonnegative_integer) and
    (.sdfSteps | nonnegative_integer) and
    (.gaussianSamples | nonnegative_integer);

(length == 1) and
(.[0] |
exact_keys(["schemaVersion", "probe", "fixtureVersion", "status", "failure", "device", "metrics"]) and
.schemaVersion == 1 and
.probe == $probe and
.fixtureVersion == 1 and
.status == "pass" and
.failure == null and
(.device | type == "string" and length > 0) and
(.metrics | type == "object") and
(.metrics as $m |
    if $probe == "shadow" then
        ($m | exact_keys(["sampleCount", "legacyMismatch", "falseShadows", "missedShadows", "maxHitDistanceError"])) and
        ($m.sampleCount | integer and . == 10380) and
        ($m.legacyMismatch | integer and . == 404) and
        ($m.falseShadows | integer and . == 0) and
        ($m.missedShadows | integer and . == 0) and
        ($m.maxHitDistanceError | nonnegative_number and . <= 0.002)
    elif $probe == "mixed" then
        ($m | exact_keys(["mixedLeafVoxel", "mixedLeafSDFRefs", "wrongNearestHits", "maxHitDistanceError", "voxelOnly", "sdfOnly", "gaussianOnly", "mixed", "empty"])) and
        $m.mixedLeafVoxel == true and
        ($m.mixedLeafSDFRefs | integer and . == 2) and
        ($m.wrongNearestHits | integer and . == 0) and
        ($m.maxHitDistanceError | nonnegative_number and . <= 0.002) and
        ($m.voxelOnly | steps and .voxelSteps > 0 and .sdfSteps == 0 and .gaussianSamples == 0) and
        ($m.sdfOnly | steps and .voxelSteps == 0 and .sdfSteps > 0 and .gaussianSamples == 0) and
        ($m.gaussianOnly | steps and .voxelSteps == 0 and .sdfSteps == 0 and .gaussianSamples > 0) and
        ($m.mixed | steps and .voxelSteps > 0 and .sdfSteps > 0 and .gaussianSamples > 0) and
        ($m.empty | steps and .voxelSteps == 0 and .sdfSteps == 0 and .gaussianSamples == 0)
    elif $probe == "budgets" then
        ($m | exact_keys(["overflowCount", "smoothSteps", "creatureSteps", "fractalSteps", "fractalIterations", "hierarchicalSteps", "surfaceLights", "localShadowRays", "sunShadowRays", "secondarySceneRays"])) and
        ($m.overflowCount | integer and . == 0) and
        ($m.smoothSteps | nonnegative_integer and . <= 24) and
        ($m.creatureSteps | nonnegative_integer and . <= 32) and
        ($m.fractalSteps | nonnegative_integer and . <= 48) and
        ($m.fractalIterations | nonnegative_integer and . <= 8) and
        ($m.hierarchicalSteps | nonnegative_integer and . <= 4096) and
        ($m.surfaceLights | nonnegative_integer and . <= 4) and
        ($m.localShadowRays | nonnegative_integer and . <= 1) and
        ($m.sunShadowRays | nonnegative_integer and . <= 1) and
        ($m.secondarySceneRays | nonnegative_integer and . <= 1)
    elif $probe == "sdf" then
        ($m | exact_keys(["maxDistanceError", "maxNormalAngleDegrees", "maxNormalLengthError", "nonFiniteCount", "negativeExteriorStepCount", "fractalCoverage"])) and
        ($m.maxDistanceError | nonnegative_number and . <= 0.0001) and
        ($m.maxNormalAngleDegrees | nonnegative_number and . <= 0.5) and
        ($m.maxNormalLengthError | nonnegative_number and . <= 0.001) and
        ($m.nonFiniteCount | integer and . == 0) and
        ($m.negativeExteriorStepCount | integer and . == 0) and
        ($m.fractalCoverage | finite_number and . > 0 and . < 0.10)
    elif $probe == "optics" then
        ($m | exact_keys(["maxReflectionDirectionError", "maxRefractionDirectionError", "tirFailureCount", "recursiveSecondaryRayCount"])) and
        ($m.maxReflectionDirectionError | nonnegative_number and . <= 0.0001) and
        ($m.maxRefractionDirectionError | nonnegative_number and . <= 0.0001) and
        ($m.tirFailureCount | integer and . == 0) and
        ($m.recursiveSecondaryRayCount | integer and . == 0)
    elif $probe == "volume" then
        ($m | exact_keys(["maxHomogeneousRelativeError", "maxGaussianRelativeError", "maxSurfaceTransmittanceRelativeError", "sunShadowRadianceRatio", "localShadowRadianceRatio", "smokeSunReceiverRatio", "smokeLocalReceiverRatio", "nonFiniteCount"])) and
        ($m.maxHomogeneousRelativeError | nonnegative_number and . <= 0.02) and
        ($m.maxGaussianRelativeError | nonnegative_number and . <= 0.02) and
        ($m.maxSurfaceTransmittanceRelativeError | nonnegative_number and . <= 0.02) and
        ($m.sunShadowRadianceRatio | nonnegative_number and . < 0.35) and
        ($m.localShadowRadianceRatio | nonnegative_number and . < 0.35) and
        ($m.smokeSunReceiverRatio | nonnegative_number and . < 1) and
        ($m.smokeLocalReceiverRatio | nonnegative_number and . < 1) and
        ($m.nonFiniteCount | integer and . == 0)
    elif $probe == "motion" then
        ($m | exact_keys(["creatureCount", "lightCount", "repeatMismatchCount", "poseDeltaAtOneSecond", "lightDeltaAtOneSecond"])) and
        ($m.creatureCount | integer and . == 6) and
        ($m.lightCount | integer and . == 6) and
        ($m.repeatMismatchCount | integer and . == 0) and
        ($m.poseDeltaAtOneSecond | finite_number and . > 0) and
        ($m.lightDeltaAtOneSecond | finite_number and . > 0)
    elif $probe == "ui" then
        ($m | exact_keys(["stateMismatchCount", "focusFailureCount", "modifierLeakCount", "accessibilityFailureCount", "responsiveLayoutFailureCount", "adaptiveScaleFailureCount", "fixedScaleFailureCount", "reduceMotionFailureCount", "windowCount"])) and
        ($m.stateMismatchCount | integer and . == 0) and
        ($m.focusFailureCount | integer and . == 0) and
        ($m.modifierLeakCount | integer and . == 0) and
        ($m.accessibilityFailureCount | integer and . == 0) and
        ($m.responsiveLayoutFailureCount | integer and . == 0) and
        ($m.adaptiveScaleFailureCount | integer and . == 0) and
        ($m.fixedScaleFailureCount | integer and . == 0) and
        ($m.reduceMotionFailureCount | integer and . == 0) and
        ($m.windowCount | integer and . == 1)
    else
        false
    end
))
