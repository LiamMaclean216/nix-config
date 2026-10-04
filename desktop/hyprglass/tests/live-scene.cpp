#include "SceneDamage.hpp"

#include <cstdlib>
#include <iostream>

using namespace GlassScene;

static void require(bool condition, const char* message) {
    if (!condition) {
        std::cerr << "scene cache regression: " << message << '\n';
        std::exit(1);
    }
}

int main() {
    const Box clock{300, 200, 179, 40};
    const Window underClock{1, {310, 210, 100, 100}, {310, 210, 100, 100}, 1, 1, 0};
    const Window elsewhere{2, {10, 10, 100, 100}, {10, 10, 100, 100}, 1, 1, 1};
    const Snapshot scene{underClock, elsewhere};

    require(changedBounds(scene, scene).empty(), "idle frames must reuse the sample");
    require(affectsSample(changedBounds({}, scene), clock), "first visible scene must capture background");

    auto moved = scene;
    moved[0].box.x += 15;
    moved[0].bounds.x += 15;
    require(affectsSample(changedBounds(scene, moved), clock), "static client drag must invalidate without a client commit");
    require(changedBounds(moved, moved).empty(), "motion must stop invalidating when geometry settles");

    moved = scene;
    moved[0].box.x = 800;
    moved[0].bounds.x = 800;
    require(affectsSample(changedBounds(scene, moved), clock), "moving away must invalidate the old covered region");
    require(affectsSample(changedBounds(moved, scene), clock), "moving into the sample must invalidate the new region");

    moved = scene;
    moved[1].box.x += 30;
    moved[1].bounds.x += 30;
    require(!affectsSample(changedBounds(scene, moved), clock), "unrelated window motion must not recapture the clock");

    const Snapshot left{{3, {0, 200, 100, 40}, {0, 200, 100, 40}, 1, 1, 0}};
    const Snapshot right{{3, {600, 200, 100, 40}, {600, 200, 100, 40}, 1, 1, 0}};
    require(!affectsSample(changedBounds(left, right), clock), "disjoint old/new bounds must not damage the gap between them");

    moved = scene;
    moved[0].box.w += 20;
    moved[0].bounds.w += 20;
    require(affectsSample(changedBounds(scene, moved), clock), "resize must invalidate");
    moved = scene;
    moved[0].opacity = 0.4F;
    require(affectsSample(changedBounds(scene, moved), clock), "opacity and close-snapshot fades must invalidate");
    moved = scene;
    moved[0].plane = 0;
    require(affectsSample(changedBounds(scene, moved), clock), "rendering plane changes must invalidate");
    moved = scene;
    moved[0].order = 1;
    moved[1].order = 0;
    require(affectsSample(changedBounds(scene, moved), clock), "stacking order changes must invalidate");

    require(affectsSample(changedBounds(scene, {elsewhere}), clock), "window removal or leaving a monitor must refresh revealed pixels");
    moved = scene;
    moved[0].identity = 4;
    require(affectsSample(changedBounds(scene, moved), clock), "replacement clients with equal geometry must invalidate");

    // The sampling padding is part of the dependency, even outside the visible pane.
    const Box padding{clock.x - 80, clock.y - 80, clock.w + 160, clock.h + 160};
    const Snapshot margin{{5, {230, 170, 30, 30}, {230, 170, 30, 30}, 1, 1, 0}};
    require(!affectsSample(changedBounds({}, margin), clock), "margin client does not directly cover pane");
    require(affectsSample(changedBounds({}, margin), padding), "blur/refraction sampling margins must invalidate");

    // Inserting a distant client shifts integer ranks without restacking any
    // existing client. It must not turn an unrelated scene change into damage.
    const Snapshot single{underClock};
    auto shifted = underClock;
    shifted.order = 1;
    auto distant = elsewhere;
    distant.order = 0;
    require(!affectsSample(changedBounds(single, {distant, shifted}), clock),
            "unrelated insertion/rank shifts must preserve the sample");
    require(!affectsSample(changedBounds({distant, shifted}, single), clock),
            "unrelated removal/rank shifts must preserve the sample");

    auto dimmed = underClock;
    dimmed.bounds = {0, 0, 1000, 1000};
    auto dimmedMove = dimmed;
    dimmedMove.box.x += 10;
    require(affectsSample(changedBounds({dimmed}, {dimmedMove}), clock),
            "moving dimAround clients must invalidate even with fixed monitor-wide bounds");
    auto shadow = elsewhere;
    shadow.box = {clock.x - 30, clock.y, 20, 20};
    shadow.bounds = {clock.x - 40, clock.y - 10, 60, 40};
    auto changedShadow = shadow;
    changedShadow.box.x -= 5;
    changedShadow.bounds.x -= 5;
    require(affectsSample(changedBounds({shadow}, {changedShadow}), clock),
            "shadow and border dependencies must invalidate beyond the body bounds");

    require(!Box{0, 0, 0, 100}.overlaps(clock), "empty geometry must not cause sample updates");
    require(!Box{clock.x - 10, clock.y, 10, 20}.overlaps(clock), "edge contact has no sample overlap");
    std::cout << "live scene cache regressions passed\n";
}
