/// The attendance targets the app accepts, in percent.
///
/// 0 would send the skip maths to its "no target" answer, and anything over
/// 100 can never be met. A target that arrives from outside the sliders (a
/// sync pull, a backup, a stored row) is held to this range on the way in.
const double lowestTarget = 1;
const double highestTarget = 100;

double targetInRange(double percent) =>
    percent.clamp(lowestTarget, highestTarget).toDouble();
