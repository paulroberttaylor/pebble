// NPC — an autonomous "virtual player".
//
// An NPC is a Player subclass, so it runs the *exact* same vanilla-physics
// travel(), the same 36-slot inventory, the same hunger/reach/breaking state the
// controlled player does. Whatever rule binds the human binds the NPC: it must
// walk into range, hold a break to completion, have the right tool, and have
// inventory space — there is no privileged path to bypass any of it. The AI only
// ever sets the same movement intents a keyboard sets (moveForward / yaw /
// jumping); it never teleport-steers and never mutates the world directly.
//
// This slice gives the NPC a *body*: grid-A* pathfinding (the shared findPath)
// translated into player intents, plus an idle wander. The *mind* (persona,
// dialogue, goal selection) is a separate async layer added later — it will only
// hand this navigator a target, never touch world state inside the tick.
//
// Determinism: every random choice flows through the per-entity seeded `rng`
// (RandomX), so the same save wanders identically on every run/replay.

import Foundation

public final class NPC: Player {
    public override var type: String { "npc" }

    /// Persona scaffolding for the future "mind" layer. Persisted now so the
    /// character's identity survives save/load before the mind exists.
    public var displayName = "Traveler"
    public var persona = ""

    // ---- navigation state (parallels Navigation, but steers Player intents) ---
    private var path: [PathNode]? = nil
    private var pathIndex = 0
    private var repathCooldown = 0
    private var navTargetX = 0.0, navTargetY = 0.0, navTargetZ = 0.0
    private var stuckTicks = 0
    private var nodeTicks = 0
    private var lastNavX = 0.0, lastNavZ = 0.0
    private var idleCooldown = 0

    public override init(world: World) {
        super.init(world: world)
        persistent = true                 // a person doesn't despawn
        setGameMode(GameMode.survival)     // bound by the same survival rules
    }

    // ---- navigation API (the mind will call navigateTo) -----------------------

    /// Request a path to a world position. Returns false if no path was found.
    /// Mirrors Navigation.moveTo: coalesces repeats and rate-limits repathing.
    @discardableResult
    public func navigateTo(_ x: Double, _ y: Double, _ z: Double) -> Bool {
        let dx = x - navTargetX, dy = y - navTargetY, dz = z - navTargetZ
        if let p = path, pathIndex < p.count, dx * dx + dy * dy + dz * dz < 1 { return true }
        navTargetX = x; navTargetY = y; navTargetZ = z
        if repathCooldown > 0 { return path != nil }
        repathCooldown = 20
        path = findPath(world, self.x, self.y, self.z, x, y, z, 600, false)
        pathIndex = 0
        stuckTicks = 0
        nodeTicks = 0
        return path != nil
    }

    public func navigationDone() -> Bool { path == nil || pathIndex >= (path?.count ?? 0) }

    public func stopNavigating() {
        path = nil
        moveForward = 0
        jumping = false
    }

    // ---- per-tick: baseLivingTick → decide intent → vanilla travel ------------
    // Order mirrors Mob.mobTick (baseLivingTick, then AI, then travel) so the
    // NPC's physics resolves against freshly-decided intents, exactly like a mob.
    public override func tick() {
        let wasDead = dead
        super.tick()                       // Player housekeeping: hunger, pickup, baseLivingTick
        if dead || wasDead { return }
        aiStep()                           // pick a wander target when idle
        followPath()                       // path → moveForward / yaw / jumping
        if vehicle == nil { travel() }     // the SAME vanilla physics the player runs
    }

    // ---- behavior -------------------------------------------------------------
    private func aiStep() {
        if repathCooldown > 0 { repathCooldown -= 1 }
        guard navigationDone() else { return }
        moveForward *= 0.5                 // coast to a stop between wanders
        if idleCooldown > 0 { idleCooldown -= 1; return }
        // idle wander: pick a nearby reachable cell and walk to it
        for _ in 0..<8 {
            let tx = ifloor(x) + rng.nextInt(21) - 10
            let tz = ifloor(z) + rng.nextInt(21) - 10
            let ty = ifloor(y) + rng.nextInt(7) - 3
            if walkable(world, tx, ty, tz, false),
               navigateTo(Double(tx) + 0.5, Double(ty), Double(tz) + 0.5) {
                break
            }
        }
        idleCooldown = 40 + rng.nextInt(80)
    }

    /// Translate the current path node into player movement intents — the same
    /// steering Navigation.tick applies to a mob, but written onto the Player
    /// intent fields that vanilla travel() consumes.
    private func followPath() {
        guard let p = path, pathIndex < p.count else { return }
        let node = p[pathIndex]
        let nx = Double(node.x) + 0.5, nz = Double(node.z) + 0.5
        let dx = nx - x, dz = nz - z
        let distSq = dx * dx + dz * dz
        // accept the node on horizontal arrival (the vertical gate is loose so we
        // don't orbit a node a block above/below us forever)
        if distSq < 0.6 * 0.6 && (abs(node.y - ifloor(y)) <= 1 || distSq < 0.35 * 0.35) {
            pathIndex += 1
            nodeTicks = 0
            return
        }
        nodeTicks += 1
        if nodeTicks > 80 { stopNavigating(); nodeTicks = 0; return }   // unreachable-node breaker
        // steer toward the node
        let targetYaw = detAtan2(-dx, dz)
        var d = targetYaw - yaw
        while d > .pi { d -= .pi * 2 }
        while d < -.pi { d += .pi * 2 }
        yaw += clampD(d, -0.35, 0.35)
        moveForward = abs(d) > 1.6 ? 0.2 : 1.0          // slow while turning hard
        jumping = (node.y > ifloor(y) && distSq < 2.5) || (horizontalCollision && onGround)
        if inWater && node.y >= ifloor(y) { jumping = true }
        // stuck breaker: no horizontal progress for 50 ticks → drop the path
        let mdx = x - lastNavX, mdz = z - lastNavZ
        let moved = (mdx * mdx + mdz * mdz).squareRoot()
        lastNavX = x; lastNavZ = z
        if moved < 0.01 {
            stuckTicks += 1
            if stuckTicks > 50 { stopNavigating(); stuckTicks = 0; repathCooldown = 0 }
        } else {
            stuckTicks = 0
        }
    }

    // ---- persistence ----------------------------------------------------------
    public override func save() -> [String: Any] {
        var d = super.save()
        d["displayName"] = displayName
        d["persona"] = persona
        return d
    }
    public override func load(_ d: [String: Any]) {
        super.load(d)
        displayName = (d["displayName"] as? String) ?? "Traveler"
        persona = (d["persona"] as? String) ?? ""
    }
}
