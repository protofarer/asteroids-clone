package game

import "core:fmt"
import rl "vendor:raylib"
import sa "core:container/small_array"
import math "core:math"
import linalg "core:math/linalg"
import rand "core:math/rand"
import "core:log"

pr :: fmt.println
Vec2 :: rl.Vector2

DEBUG :: false
WINDOW_W :: 1000
WINDOW_H :: 750
LOGICAL_W :: 1000
LOGICAL_H :: 750

PHYSICS_HZ :: 60
// FIXED_DT :: 1 / PHYSICS_HZ

MAX_ENTITIES :: 64

TIMER_INTERVAL_INTRO_MESSAGE :: 4
TIMER_INTERVAL_BETWEEN_LEVELS :: 2

SHIP_R :: 22
SHIP_ROTATION_MAGNITUDE :: 5
SHIP_MAX_SPEED :: 350
THRUST_MAGNITUDE :: 6
SPACE_FRICTION_COEFFICIENT :: 0.01 // cause of plasma and charged dust
TIMER_INTERVAL_THRUST_DRAW :: 0.075

TIMER_INTERVAL_TELEPORT :: 1
TIMER_INTERVAL_DEATH :: 1
TIMER_INTERVAL_SPAWN :: 2

SHIP_BULLET_COUNT_LIMIT :: 4
BULLET_SPEED :: 500
BULLET_LIFESPAN_SPEED_RATIO :: 0.0018
BULLET_LIFESPAN :: BULLET_SPEED * BULLET_LIFESPAN_SPEED_RATIO
BULLET_PHYSICS_RADIUS :: 1

N_ASTEROID_SIDES :: 8
SMALL_ASTEROID_RADIUS :: 15
MEDIUM_ASTEROID_RADIUS :: SMALL_ASTEROID_RADIUS * 2
LARGE_ASTEROID_RADIUS :: SMALL_ASTEROID_RADIUS * 4

BIG_UFO_RADIUS :: 25
BIG_UFO_SPEED :: 150
BASE_CHANCE_SPAWN_BIG :: 0.1
// BASE_CHANCE_SPAWN_BIG :: 0.5 // TEST
TIMER_INTERVAL_UFO_BIG_MOVE :: 0.5
BIG_UFO_CHANCE_TO_MOVE :: 1
TIMER_INTERVAL_UFO_BIG_SHOOT :: 1
BIG_UFO_CHANCE_TO_SHOOT :: 0.4


SMALL_UFO_RADIUS :: 15
SMALL_UFO_SPEED :: 165
BASE_CHANCE_SPAWN_SMALL :: 0.025
// BASE_CHANCE_SPAWN_SMALL :: 0.5 // TEST
TIMER_INTERVAL_UFO_SMALL_MOVE :: 0.2
SMALL_UFO_CHANCE_TO_MOVE :: 1
TIMER_INTERVAL_UFO_SMALL_SHOOT :: 0.75
SMALL_UFO_CHANCE_TO_SHOOT :: .5

TIMER_INTERVAL_BEAT :: 15
TIMER_INTERVAL_UFO :: 5
INIT_TIMER_INTERVAL_BEAT_SOUND :: 1

Game_Memory :: struct {
	using manager: ^Entity_Manager,
    sounds: [Sound_Kind]rl.Sound,
    game_state: Game_State,
    ship_state: Ship_State,
	player_id: Entity_Id,
    death_timer: Timer,
    spawn_timer: Timer,
    between_levels_timer: Timer,
    beat_level_timer: Timer,
    ufo_timer: Timer,
    beat_sound_timer: Timer,
    thrust_draw_timer: Timer,
    teleport_timer: Timer,
    intro_timer: Timer,
    score: i32,
    level: i32,
    lives: i32,
    extra_life_count: i32,
    beat_level: i32,
    ship_active_bullets: i32,
	run: bool,
    is_thrust_drawing: bool,
    is_beat_sound_hi: bool,
    is_gesture_tap: bool,
    is_gesture_hold: bool,
    is_gesture_hold_right: bool,
    is_gesture_hold_left: bool,
}
g_mem: ^Game_Memory

Game_State :: enum {
    Intro,
    Between_Levels,
    Play,
    Game_Over,
}

Ship_State :: enum {
    Normal,
    Death,
    Spawning,
    Teleporting,
}

Timer :: struct {
    accum: f32,
    interval: f32,
}

Sound_Kind :: enum {
    Fire,
    Score,
    Bullet_Impact,
    Thrust,
    Asteroid_Explode,
    Death,
    Beat_Lo,
    Beat_Hi,
    Ufo_Alarm,
}

Entity_Id :: distinct u32

Entity_Manager :: struct {
	entities: sa.Small_Array(MAX_ENTITIES, Entity_Id),
    n_active: int,
	free_list: sa.Small_Array(MAX_ENTITIES, Entity_Id),
	entity_to_index: map[Entity_Id]int,
    components: ^#soa[MAX_ENTITIES]Big_Component,
}
components: ^#soa[MAX_ENTITIES]Big_Component

Entity_Type :: enum { 
    None,
    Ship, 
    Asteroid_Large, 
    Asteroid_Medium, 
    Asteroid_Small, 
    Bullet, 
    Ufo_Big,
    Ufo_Small,
}

Big_Component :: struct {
    type: Entity_Type,
	position: Vec2,
	velocity: Vec2,
	rotation: f32,
	radius: f32,
    lifespan: f32,
    shot_timer: Timer,
    move_timer: Timer,
    shooter: Shooter_Type,
	visual_rotation_rate: f32, // asteroid visual rotation
}

Shooter_Type :: enum {
    None,
    Ship,
    Ufo,
}

Spawn_Asteroid_Data :: struct {
    type: Entity_Type,
    pos: Vec2,
    vel: Vec2,
}

touch_pos: Vec2
touch_area: rl.Rectangle
current_gesture: rl.Gestures
last_gesture: rl.Gestures

ship_vertices: [5]Vec2
ship_thrust_vertices: [3]Vec2
death_particles_start_positions := [?]Vec2{
    {10, 0},
    {5, 5},
    {0, 10},
    {-5, 5},
    {0, -10},
    {-5, -5},
    {-10, 0},
    {5, -5},
}
death_particles_end_positions := [?]Vec2{
    {50, 0},
    {25, 25},
    {0,50},
    {-25, 25},
    {0,-50},
    {-25, -25},
    {-50, 0},
    {25, -25},
}
big_ufo_outline_vertices: [9]Vec2
big_ufo_body_line: [2]Vec2
big_ufo_canopy_line: [2]Vec2
small_ufo_outline_vertices: [9]Vec2
small_ufo_body_line: [2]Vec2
small_ufo_canopy_line: [2]Vec2

game_camera :: proc() -> rl.Camera2D {
	w := f32(rl.GetScreenWidth())
	h := f32(rl.GetScreenHeight())
	return {
		zoom = h/LOGICAL_H,
		offset = { w/2, h/2 },
	}
}

ui_camera :: proc() -> rl.Camera2D {
	return {
		zoom = 1,
	}
}

update :: proc() {
	if rl.IsKeyPressed(.ESCAPE) {
		g_mem.run = false
	}
    process_gestures()
    eval_game_over()
    if g_mem.game_state == .Game_Over do return

    dt := rl.GetFrameTime()

    if g_mem.game_state == .Intro {
        if process_timer(&g_mem.intro_timer) {
            g_mem.game_state = .Between_Levels
        }
        return
    }

    update_entities(dt)
    handle_collisions()
    update_lifespans(dt)

    if get_score() > (get_extra_life_count() + 1) * 10000 {
        increment_extra_life_count()
    }

    // Level spawning and between-level pause
    level_spawn_and_transition()

    // beat level
    if process_timer(&g_mem.beat_level_timer) {
        g_mem.beat_level = clamp(g_mem.beat_level + 1, 1, 4)
        update_beat_sound_timer_with_level(g_mem.beat_level)
    }

    // beat sound
    if process_timer(&g_mem.beat_sound_timer) {
        if g_mem.is_beat_sound_hi {
            rl.PlaySound(g_mem.sounds[.Beat_Hi])
        } else {
            rl.PlaySound(g_mem.sounds[.Beat_Lo])
        }
        g_mem.is_beat_sound_hi = !g_mem.is_beat_sound_hi
    }

    // Spawn Ufos
    spawner_ufo(g_mem.beat_level, dt)
}

process_gestures :: proc() {
    g_mem.is_gesture_hold = false
    g_mem.is_gesture_hold_left = false
    g_mem.is_gesture_hold_right = false
    g_mem.is_gesture_tap = false

    last_gesture = current_gesture
    current_gesture = rl.GetGestureDetected()
    touch_pos = rl.GetTouchPosition(0)
    valid_touch := rl.CheckCollisionPointRec(touch_pos, touch_area)
    if valid_touch && current_gesture != nil {
        switch {
        case .TAP in current_gesture:
            g_mem.is_gesture_tap = true
        case .HOLD in current_gesture, .DRAG in current_gesture:
            g_mem.is_gesture_hold = true
            if touch_pos.x < (f32(rl.GetScreenWidth()) / 2) && touch_pos.y > (f32(rl.GetScreenHeight()) / 2) {
                g_mem.is_gesture_hold_left = true
            } else if touch_pos.x > (f32(rl.GetScreenWidth()) / 2) && touch_pos.y > (f32(rl.GetScreenHeight()) / 2) {
                g_mem.is_gesture_hold_right = true
            }
        }
    }
}

level_spawn_and_transition :: proc() {
    if get_asteroid_count() == 0 && g_mem.game_state == .Play {
        g_mem.game_state = .Between_Levels
    } else if g_mem.game_state == .Between_Levels {
        if process_timer(&g_mem.between_levels_timer) {
            g_mem.game_state = .Play
            restart_timer(&g_mem.beat_level_timer)
            restart_timer(&g_mem.beat_sound_timer)
            g_mem.beat_level = 1
            update_beat_sound_timer_with_level(1)
            spawn_level()
        }
    }
}

update_lifespans :: proc(dt: f32) {
    bullets_with_expired_lifespans: [dynamic]int
    defer delete(bullets_with_expired_lifespans)
    for index in 0..<get_active_entity_count() {
        type := components[index].type
        if type == .Bullet {
            lifespan := components[index].lifespan
            new_lifespan := lifespan - dt
            if new_lifespan <= 0 {
                append(&bullets_with_expired_lifespans, index)
            } else {
                components[index].lifespan = new_lifespan
            }
        }
    }
    for index_to_expire in bullets_with_expired_lifespans {
        shooter := components[index_to_expire].shooter
        if shooter == .Ship {
            g_mem.ship_active_bullets -= 1
        }
        destroy_entity(index_to_expire)
    }
}


spawner_ufo :: proc(beat_level: i32, dt: f32) {
    if !process_timer(&g_mem.ufo_timer) {
        return
    }

    base_chance_big : f32 = BASE_CHANCE_SPAWN_BIG
    big_spawn_factor := base_chance_big * (1 + f32(beat_level) * 0.07)

    base_chance_small : f32 = BASE_CHANCE_SPAWN_SMALL
    small_spawn_factor := base_chance_small * (1 + f32(beat_level) * 0.07)

    spawn_ufo_type: Entity_Type
    rgn_spawn := rand.float32()
    if rgn_spawn < big_spawn_factor {
        spawn_ufo_type = .Ufo_Big
    } else if rgn_spawn < big_spawn_factor + small_spawn_factor {
        spawn_ufo_type = .Ufo_Small
    }

    if spawn_ufo_type == .None {
        return
    }

    rgn_pos := rand.float32_range(0, 2)
    span_y := f32(play_span_y())
    if rgn_pos < 1 {
        // spawn left wall
        pos_y := (rgn_pos * span_y * 0.8) + (span_y * 0.1) - (span_y / 2)
        pos_x := f32(play_edge_left())
        spawn_ufo(spawn_ufo_type, {pos_x, pos_y}, true)
    } else {
        // spawn right wall
        pos_y := ((rgn_pos - 1) * span_y * 0.8) + (span_y * 0.1) - (span_y / 2)
        pos_x := f32(play_edge_right())
        spawn_ufo(spawn_ufo_type, {pos_x, pos_y}, false)
    }
}

get_asteroid_count :: proc() -> i32 {
    count : i32 = 0
    for i in 0..<get_active_entity_count() {
        if components.type[i] == .Asteroid_Large || components.type[i] == .Asteroid_Medium || components.type[i] == .Asteroid_Small {
            count += 1
        }
    }
    return count
}

spawn_level :: proc() {
    SPAWN_OFFSET :: 10
    for _ in 0..<g_mem.level+3 {
        unit_direction := make_random_direction()
        speed := rand.float32_range(50,120)
        vel := speed * unit_direction

        pos: Vec2

        rgn := rand.float32_range(0, 4)
        // top boundary
        if rgn < 1 {
            span_proportion := rgn
            dx := span_proportion * f32(play_span_x())
            x := f32(play_edge_left()) + dx
            y := f32(play_edge_top()) + SPAWN_OFFSET
            pos = {x,y}

        // right boundary
        } else if rgn < 2 {
            span_proportion := rgn - 1
            dy := span_proportion * f32(play_span_y())
            x := f32(play_edge_right()) - SPAWN_OFFSET
            y := f32(play_edge_top()) + dy
            pos = {x,y}

        // bot boundary
        } else if rgn < 3 {
            span_proportion := rgn - 2
            dx := span_proportion * f32(play_span_x())
            x := f32(play_edge_left()) + dx
            y := f32(play_edge_bottom()) - SPAWN_OFFSET
            pos = {x,y}

        // left boundary
        } else if rgn < 4 {
            span_proportion := rgn - 3
            dy := span_proportion * f32(play_span_y())
            x := f32(play_edge_left()) + SPAWN_OFFSET
            y := f32(play_edge_top()) + dy
            pos = {x,y}
        }
        spawn_asteroid(.Asteroid_Large, pos, vel)
    }
    g_mem.level += 1
}

draw :: proc() {
	rl.BeginDrawing()
	rl.ClearBackground(rl.BLACK)

	rl.BeginMode2D(game_camera())
    draw_screen_edges()
	draw_entities() 
	rl.EndMode2D()

	rl.BeginMode2D(ui_camera())
	draw_debug_ui()
    draw_ui()
	rl.EndMode2D()

	rl.EndDrawing()
}

// Screen edges are all within play area. The drawn boundary line currently within play area
play_edge_left :: proc() -> i32 {
    return i32(screen_left() + 1)
}
play_edge_top :: proc() -> i32 {
    return i32(screen_top() + 2)
}
play_edge_right :: proc() -> i32 {
    return i32(play_edge_left() + LOGICAL_W - 2)
}
play_edge_bottom :: proc() -> i32 {
    return i32(play_edge_top() + LOGICAL_H - 3)
}
play_span_x :: proc() -> i32 {
    return i32(play_edge_right() - play_edge_left())
}
play_span_y :: proc() -> i32 {
    return i32(play_edge_bottom() - play_edge_top())
}
draw_screen_edges :: proc() {
    rl.DrawRectangleLines(i32(screen_left() + 1), i32(screen_top() + 1), LOGICAL_W - 2, LOGICAL_H - 2, rl.RAYWHITE)
}

@(export)
game_update :: proc() {
	update()
	draw()
}

@(export)
game_init_window :: proc() {
    log.info("init window")
    // .Borderlesswindowedmode, .fullscreen_mode, window_maximized
	rl.SetConfigFlags({.VSYNC_HINT, .WINDOW_RESIZABLE})
	rl.InitWindow(WINDOW_W, WINDOW_H, "Asteroids")
	rl.SetWindowPosition(50, 150)
	rl.SetTargetFPS(PHYSICS_HZ)
	rl.SetExitKey(nil)
    rl.InitAudioDevice()
}

@(export)
game_init :: proc() {
    context.logger = log.create_console_logger()
    log.info("init game")
	g_mem = new(Game_Memory)
	g_mem.manager = new(Entity_Manager)
	g_mem.manager.components = new(#soa[MAX_ENTITIES]Big_Component)
    components = g_mem.manager.components
    for sound_kind in Sound_Kind {
        g_mem.sounds[sound_kind] = load_sound_from_kind(sound_kind)
    }
	g_mem.run = true
    g_mem.ship_state = .Normal
    g_mem.game_state = .Intro
    g_mem.lives = 3
    g_mem.level = 1
    g_mem.beat_level = 1
    g_mem.death_timer = Timer {
        accum = TIMER_INTERVAL_DEATH,
        interval = TIMER_INTERVAL_DEATH,
    }
    g_mem.spawn_timer = Timer {
        accum = TIMER_INTERVAL_SPAWN,
        interval = TIMER_INTERVAL_SPAWN,
    }
    g_mem.between_levels_timer = Timer {
        accum = TIMER_INTERVAL_BETWEEN_LEVELS,
        interval = TIMER_INTERVAL_BETWEEN_LEVELS,
    }
    g_mem.beat_level_timer = Timer {
        accum = TIMER_INTERVAL_BEAT,
        interval = TIMER_INTERVAL_BEAT,
    }
    g_mem.ufo_timer = Timer {
        accum = TIMER_INTERVAL_UFO,
        interval = TIMER_INTERVAL_UFO,
    }
    g_mem.beat_sound_timer = Timer {
        accum = INIT_TIMER_INTERVAL_BEAT_SOUND,
        interval = INIT_TIMER_INTERVAL_BEAT_SOUND,
    }
    g_mem.thrust_draw_timer = Timer {
        accum = TIMER_INTERVAL_THRUST_DRAW,
        interval = TIMER_INTERVAL_THRUST_DRAW,
    }
    g_mem.teleport_timer = Timer {
        accum = TIMER_INTERVAL_TELEPORT,
        interval = TIMER_INTERVAL_TELEPORT,
    }
    g_mem.intro_timer = Timer {
        accum = TIMER_INTERVAL_INTRO_MESSAGE,
        interval = TIMER_INTERVAL_INTRO_MESSAGE,
    }

    init_ufo_vertices()
    init_ship_vertices()
    init_ship_thrust_vertices()

    touch_area = {0, 0, f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight())}
    current_gesture = nil
    last_gesture = nil

	player_id := spawn_ship({0,0}, math.to_radians(f32(-90)))
    g_mem.player_id = player_id

	game_hot_reloaded(g_mem)
}

// clear and init
reset_gameplay_data :: proc() {
    // Reset globals
    g_mem.player_id = 0
    g_mem.run = true
    g_mem.ship_state = .Normal
    g_mem.game_state = .Intro
    g_mem.score = 0
    g_mem.lives = 3
    g_mem.extra_life_count = 0
    g_mem.beat_level = 0
    g_mem.ship_active_bullets = 0
    g_mem.is_beat_sound_hi = false
    g_mem.is_thrust_drawing = false
    g_mem.ship_active_bullets = 0
    g_mem.level = 1

    restart_timer(&g_mem.death_timer)
    restart_timer(&g_mem.spawn_timer)
    restart_timer(&g_mem.between_levels_timer)
    restart_timer(&g_mem.beat_level_timer)
    restart_timer(&g_mem.ufo_timer)
    restart_timer(&g_mem.thrust_draw_timer)
    restart_timer(&g_mem.teleport_timer)
    restart_timer(&g_mem.intro_timer)

    // because the interval evolves over time
    g_mem.beat_sound_timer = Timer {
        accum = INIT_TIMER_INTERVAL_BEAT_SOUND,
        interval = INIT_TIMER_INTERVAL_BEAT_SOUND,
    }

    // Reset Entity Manager
    free(g_mem.manager.components)
    free(g_mem.manager)
    g_mem.manager = new(Entity_Manager)
	g_mem.manager.components = new(#soa[MAX_ENTITIES]Big_Component)
    current_gesture = nil
    last_gesture = nil

	player_id := spawn_ship({0,0}, math.to_radians(f32(-90)))
    g_mem.player_id = player_id

    components = g_mem.manager.components
}


@(export)
game_hot_reloaded :: proc(mem: rawptr) { 
    g_mem = (^Game_Memory)(mem) 
}

@(export)
game_should_run :: proc() -> bool {
	when ODIN_OS != .JS {
		// Never run this proc in browser. It contains a 16 ms sleep on web!
		if rl.WindowShouldClose() {
			return false
		}
	}
	return g_mem.run
}

@(export)
game_shutdown :: proc() { 
    for sound in g_mem.sounds {
        rl.UnloadSound(sound)
    }
    free(g_mem) 
}

@(export)
game_shutdown_window :: proc() { 
    rl.CloseWindow() 
}

@(export)
game_memory :: proc() -> rawptr { 
    return g_mem 
}

@(export)
game_memory_size :: proc() -> int { 
    return size_of(Game_Memory) 
}

@(export)
game_force_reload :: proc() -> bool { 
    return rl.IsKeyPressed(.F6) || rl.IsKeyPressed(.R) 
}

@(export)
game_force_restart :: proc() -> bool { 
    return rl.IsKeyPressed(.F7) 
}

// In a web build, this is called when browser changes size. Remove the
// `rl.SetWindowSize` call if you don't want a resizable game.
game_parent_window_size_changed :: proc(w, h: int) {
	rl.SetWindowSize(i32(w), i32(h))
}

draw_entities :: proc() {
    dt := rl.GetFrameTime()
    for index in 0..<get_active_entity_count() {
        pos := components[index].position
        rot := components[index].rotation
        entity_type := components[index].type

        switch entity_type {
        case .Ship:
            switch g_mem.ship_state {
            case .Normal:
                draw_ship(pos, rot)
                if g_mem.is_thrust_drawing {
                    draw_ship_thruster(pos, rot)
                }
            case .Death:
                draw_ship_death(pos)
            case .Spawning:
                draw_ship_spawning(pos, rot, dt)
            case .Teleporting:
            }
        case .Asteroid_Small, .Asteroid_Medium, .Asteroid_Large:
            radius := components[index].radius
            draw_asteroid(pos, rot, radius)
        case .Bullet:
            draw_bullet(pos)
        case .Ufo_Big, .Ufo_Small:
            draw_ufo(pos, entity_type)
            if DEBUG {
                radius := components[index].radius
                 rl.DrawCircleLinesV(pos, radius, rl.BLUE)
            }
        case .None:
        }
    }
}

init_ufo_vertices :: proc() {
    offset := Vec2{0, 1} // fit better within collision circle
    {
        r :f32= BIG_UFO_RADIUS
        b :f32= r // body half length
        s1 :f32= r * 0.4 // top and bottom body half lengths
        h1 :f32= r * 0.37 // body half height, canopy height
        c1 :f32= r * 0.25 // canopy half length
        outline_vertices := [?]Vec2 {
            {-b, 0},
            {-s1, -h1},
            {-c1, -2*h1},
            {c1, -2*h1},
            {s1, -h1},
            {b, 0},
            {s1, h1},
            {-s1, h1},
            {-b, 0},
        }
        for &v in outline_vertices {
            v += offset
        }
        big_ufo_outline_vertices = outline_vertices

        body_line := [?]Vec2{
            {-b, 0},
            {b, 0},
        }
        for &v in body_line {
            v += offset
        }
        big_ufo_body_line = body_line

        canopy_line := [?]Vec2{
            {-s1, -h1},
            {s1, -h1},
        }
        for &v in canopy_line {
            v += offset
        }
        big_ufo_canopy_line = canopy_line
    }
    {
        r :f32= SMALL_UFO_RADIUS
        b :f32= r // body half length
        s1 :f32= r * 0.4 // top and bottom body half lengths
        h1 :f32= r * 0.37 // body half height, canopy height
        c1 :f32= r * 0.25 // canopy half length
        outline_vertices := [?]Vec2 {
            {-b, 0},
            {-s1, -h1},
            {-c1, -2*h1},
            {c1, -2*h1},
            {s1, -h1},
            {b, 0},
            {s1, h1},
            {-s1, h1},
            {-b, 0},
        }
        for &v in outline_vertices {
            v += offset
        }
        small_ufo_outline_vertices = outline_vertices
        body_line := [?]Vec2{
            {-b, 0},
            {b, 0},
        }
        for &v in body_line {
            v += offset
        }
        small_ufo_body_line = body_line

        canopy_line := [?]Vec2{
            {-s1, -h1},
            {s1, -h1},
        }
        for &v in canopy_line {
            v += offset
        }
        small_ufo_canopy_line = canopy_line
    }
}

draw_ufo :: proc(pos: Vec2, entity_type: Entity_Type) {
    outline_vertices: [9]Vec2
    body_line: [2]Vec2
    canopy_line: [2]Vec2
    if entity_type == .Ufo_Big {
        outline_vertices =  big_ufo_outline_vertices 
        body_line = big_ufo_body_line
        canopy_line = big_ufo_canopy_line
    } else if entity_type == .Ufo_Small {
        outline_vertices = small_ufo_outline_vertices
        body_line = small_ufo_body_line
        canopy_line = small_ufo_canopy_line
    } else {
        log.warnf("Invalid entity_type for draw_ufo: %v", entity_type)
        rl.DrawRectangleV(pos, {5, 5}, rl.RED)
        return
    }
    for i in 0..<len(outline_vertices) - 1 {
        rl.DrawLineV(outline_vertices[i] + pos, outline_vertices[i+1] + pos, rl.RAYWHITE)
    }
    rl.DrawLineV(body_line[0] + pos, body_line[1] + pos, rl.RAYWHITE)
    rl.DrawLineV(canopy_line[0] + pos, canopy_line[1] + pos, rl.RAYWHITE)
}

draw_bullet :: proc(pos: Vec2) {
    rl.DrawRectangle(i32(pos.x), i32(pos.y), 3, 3, rl.RAYWHITE)
}

draw_ship_spawning :: proc(pos: Vec2, rot: f32, dt: f32) {
    @(static) blink_accum : f32 = 0.2
    @(static) is_visible := true
    blink_interval :f32= 0.2
    blink_accum -= dt
    if blink_accum <= 0 {
        is_visible = !is_visible
        blink_accum = blink_interval
    }
    if is_visible {
        draw_ship(pos, rot)
    }
}

draw_ship_death :: proc(pos: Vec2) {
    for i in 0..<len(death_particles_start_positions) {
        t := (g_mem.death_timer.interval - g_mem.death_timer.accum) / g_mem.death_timer.interval
        pos_x := math.lerp(pos.x + death_particles_start_positions[i].x, pos.x + death_particles_end_positions[i].x, t)
        pos_y := math.lerp(pos.y + death_particles_start_positions[i].y, pos.y + death_particles_end_positions[i].y, t)
        rl.DrawPixelV({pos_x, pos_y}, rl.RAYWHITE)
    }
}

init_ship_vertices :: proc() {
    r : f32 = SHIP_R
    s : f32 = r * 1.63 // side length
    b : f32 = r * 0.25 // butt length
    nose_angle := math.to_radians(f32(32))

     // nose
    ship_vertices[0] = Vec2{r, 0}

    // sides
    ship_vertices[1] =  Vec2{r - s * math.cos(nose_angle/2), -r * math.sin(nose_angle)} // left edge
    ship_vertices[2] =  Vec2{r - s * math.cos(nose_angle/2), r * math.sin(nose_angle)} // right edge

     // butt
    b_half_y := (b + r) * math.tan(nose_angle/2) + 1 // add 1, pixel connecting butt to side may or may not render depending on s(?) or r
    ship_vertices[3] = Vec2{-b, -b_half_y}
    ship_vertices[4] = Vec2{-b, b_half_y}
}

draw_ship :: proc(pos: Vec2, rot: f32, scale: f32 = 1) {
    scaled_vertices := ship_vertices
    for &v in scaled_vertices {
        v *= scale
    }
    for &vertex in scaled_vertices[:5] {
        vertex = rotate_point(vertex, {0, 0}, rot) + pos
    }
    rl.DrawLineV(scaled_vertices[0], scaled_vertices[1], rl.RAYWHITE)
    rl.DrawLineV(scaled_vertices[0], scaled_vertices[2], rl.RAYWHITE)
    rl.DrawLineV(scaled_vertices[3], scaled_vertices[4], rl.RAYWHITE)

    if DEBUG {
        rl.DrawPixelV(pos, rl.RAYWHITE)
        radius := components[get_player_index()].radius
        rl.DrawCircleLinesV(pos, radius, rl.BLUE)
    }
}
init_ship_thrust_vertices :: proc() {
    r : f32 = SHIP_R
    b : f32 = r * 0.25 // butt length
    t := b + (r * 0.5) // thrust exhaust length
    nose_angle := math.to_radians(f32(32))
    b_half_y := (b + r) * math.tan(nose_angle/2) + 1 // add 1, pixel connecting butt to side may or may not render depending on s(?) or r
    ship_thrust_vertices[0] =  Vec2{-t, 0}
    ship_thrust_vertices[1] = Vec2{-b, -(b_half_y * 0.6)}
    ship_thrust_vertices[2] =  Vec2{-b, (b_half_y * 0.6)}
}

draw_ship_thruster :: proc(pos: Vec2, rot: f32, scale: f32 = 1) {
    scaled_vertices := ship_thrust_vertices
    for &v in scaled_vertices {
        v *= scale
    }
    for &vertex in scaled_vertices {
        vertex = rotate_point(vertex, {0, 0}, rot) + pos
    }
    rl.DrawLineV(scaled_vertices[0], scaled_vertices[1], rl.RAYWHITE)
    rl.DrawLineV(scaled_vertices[0], scaled_vertices[2], rl.RAYWHITE)
}

rotate_point :: proc(point: Vec2, center: Vec2, rot: f32 /* rad */) -> Vec2 {
    delta := point - center
    point_rotated := Vec2{
        delta.x * math.cos(rot) - delta.y * math.sin(rot) + center.x,
        delta.x * math.sin(rot) + delta.y * math.cos(rot) + center.y,
    }
    return point_rotated
}

get_last_entity_index :: proc() -> int {
    return g_mem.manager.n_active - 1
}

get_active_entity_count :: proc() -> int {
    return g_mem.manager.n_active
}

generate_entity_id :: proc() -> Entity_Id {
    return Entity_Id(get_active_entity_count())
}

create_entity :: proc(entity_type: Entity_Type) -> Entity_Id {
    manager := g_mem.manager
    index := manager.n_active
	if index >= MAX_ENTITIES {
		log.warn("Failed to create entity, max entities reached")
        return 99999
	}

    // Get ID from free list or create new
    id: Entity_Id
    if sa.len(manager.free_list) > 0 {
        id = sa.pop_back(&manager.free_list)
        reset_entity_components(index) // WARN: not sure if needed in this index based system
    } else {
        id = generate_entity_id()
    }
    sa.append(&manager.entities, id)
    g_mem.manager.n_active += 1
    manager.entity_to_index[id] = index
    return id
}

destroy_entity :: proc(index_to_destroy: int) {
    id_to_destroy := get_entity_id(index_to_destroy)
    manager := g_mem.manager
    index_to_swap, ok := manager.entity_to_index[id_to_destroy]
    if !ok {
        s := fmt.aprintf("Failed to destroy entity, no index mapped to id:", id_to_destroy)
        log.warn(s)
        return
    }
    // Get the last active entity. n_active--
    swap_data, last_id, last_index_before_pop := _pop_back_entity()

    // Swap components only if entity_destroyed isn't last entity
    if index_to_swap != last_index_before_pop {
        set_component_data(id_to_destroy, swap_data)
    }

    sa.set(&manager.entities, index_to_swap, last_id)
    manager.entity_to_index[last_id] = index_to_swap
    sa.append(&manager.free_list, id_to_destroy)
    delete_key(&manager.entity_to_index, id_to_destroy)
}

_pop_back_entity :: proc() -> (Big_Component, Entity_Id, int) {
    last_index := get_last_entity_index()
    last_id := sa.pop_back(&g_mem.manager.entities)
    g_mem.manager.n_active -= 1
    data := Big_Component{
        type = g_mem.manager.components[last_index].type,
        position = g_mem.manager.components[last_index].position,
        velocity = g_mem.manager.components[last_index].velocity,
        rotation = g_mem.manager.components[last_index].rotation,
        radius = g_mem.manager.components[last_index].radius,
        lifespan = g_mem.manager.components[last_index].lifespan,
        visual_rotation_rate = g_mem.manager.components[last_index].visual_rotation_rate,
        move_timer = g_mem.manager.components[last_index].move_timer,
        shot_timer = g_mem.manager.components[last_index].shot_timer,
        shooter = g_mem.manager.components[last_index].shooter,
    }
    return data, last_id, last_index
}

set_component_data :: proc(id: Entity_Id, data: Big_Component) -> bool {
    idx, ok_idx := g_mem.manager.entity_to_index[id]
    if !ok_idx {
        s := fmt.aprint("Failed to set component data, no index mapped to id:", id)
        log.warn(s)
        return false
    }
    components[idx] = {
        type = data.type,
        position = data.position,
        velocity = data.velocity,
        radius = data.radius,
        rotation = data.rotation,
        lifespan = data.lifespan,
        visual_rotation_rate = data.visual_rotation_rate,
        move_timer = data.move_timer,
        shot_timer = data.shot_timer,
        shooter = data.shooter,
    }
    return true
}

update_ship :: proc(index: int) {
    dt := rl.GetFrameTime()
    switch g_mem.ship_state {
    case .Death:
        if process_timer(&g_mem.death_timer) {
            if g_mem.lives <= 0 {
                set_game_over()
            } else {
                g_mem.ship_state = .Spawning
                components[get_player_index()].position = {}
                components[index].rotation = math.to_radians(f32(-90))
            }
        }
    case .Teleporting:
        if process_timer(&g_mem.teleport_timer) {
            rgn_pos_x := rand.float32_range(-0.4, 0.4) * f32(play_span_x())
            rgn_pos_y := rand.float32_range(-0.4, 0.4) * f32(play_span_y())
            new_pos := Vec2{rgn_pos_x, rgn_pos_y}
            components[index].position = new_pos
            g_mem.ship_state = .Normal
        }
    case .Spawning, .Normal:
        if g_mem.ship_state == .Spawning {
            if process_timer(&g_mem.spawn_timer) {
                g_mem.ship_state = .Normal
            }
        }
        if rl.IsKeyPressed(.LEFT_SHIFT) || rl.IsKeyPressed(.RIGHT_SHIFT)  {
            g_mem.ship_state = .Teleporting
            components[index].velocity = {}
        }
        is_thrusting := rl.IsKeyDown(.UP) || rl.IsKeyDown(.W) || g_mem.is_gesture_hold
        if is_thrusting {
            if process_timer(&g_mem.thrust_draw_timer) {
                g_mem.is_thrust_drawing = !g_mem.is_thrust_drawing
            }
            if !rl.IsSoundPlaying(g_mem.sounds[.Thrust]) {
                rl.PlaySound(g_mem.sounds[.Thrust])
            }
        }

        is_thrusting_up := (rl.IsKeyReleased(.UP) || rl.IsKeyReleased(.W)) && !g_mem.is_gesture_hold
        if is_thrusting_up {
            restart_timer(&g_mem.thrust_draw_timer)
            g_mem.is_thrust_drawing = false
        }

        d_rot: f32
        if rl.IsKeyDown(.LEFT) || rl.IsKeyDown(.A) || g_mem.is_gesture_hold_left {
            d_rot = -SHIP_ROTATION_MAGNITUDE
        }
        if rl.IsKeyDown(.RIGHT) || rl.IsKeyDown(.D) || g_mem.is_gesture_hold_right {
            d_rot = SHIP_ROTATION_MAGNITUDE
        }

        if rl.IsKeyPressed(.SPACE) || g_mem.is_gesture_tap {
            if g_mem.ship_active_bullets < SHIP_BULLET_COUNT_LIMIT {
                spawn_bullet_from_ship()
                rl.PlaySound(g_mem.sounds[.Fire])
                if g_mem.ship_state == .Spawning {
                    g_mem.ship_state = .Normal
                }
            }
        }

        rot := components[index].rotation
        new_rot := rot + d_rot * dt
        components[index].rotation = new_rot

        vel := components[index].velocity
        new_vel := vel
        if !is_thrusting {
            new_vel -= new_vel * SPACE_FRICTION_COEFFICIENT
        } else {
            heading : Vec2 = {math.cos(new_rot), math.sin(new_rot)} // aka facing, not ship velocity nor direction of movement of body
            new_vel += THRUST_MAGNITUDE * heading
        }

        if linalg.length(new_vel) > SHIP_MAX_SPEED {
            dir := linalg.normalize0(new_vel)
            new_vel = dir * SHIP_MAX_SPEED
        }

        speed := linalg.length(new_vel)
        if speed <= 3 {
            new_vel = Vec2{}
        }

        components[index].velocity = new_vel
    }
}

update_entities :: proc( dt: f32) {
    entities_to_destroy_behavioral: [dynamic]int
    defer delete(entities_to_destroy_behavioral)

    n_active_entities := get_active_entity_count()
	for index in 0..<n_active_entities {

        // Entity Autonomous Behavior
        entity_type := components[index].type
        switch entity_type {
		case .Ship:
            update_ship(index)
		case .Asteroid_Small, .Asteroid_Medium, .Asteroid_Large:
            rot := components[index].rotation
            visual_rotation_rate := components[index].visual_rotation_rate
            new_rot := rot + visual_rotation_rate
            components[index].rotation = new_rot
		case .Bullet:
        case .Ufo_Big, .Ufo_Small:
            if !rl.IsSoundPlaying(g_mem.sounds[.Ufo_Alarm]) {
                rl.PlaySound(g_mem.sounds[.Ufo_Alarm])
            }

            vel := components[index].velocity
            move_timer := components[index].move_timer
            process_ufo_move(index, dt, move_timer, vel, entity_type)

            shot_timer := components[index].shot_timer
            pos := components[index].position
            process_ufo_shot(index, dt, shot_timer, entity_type, pos)
        case .None:
		}

        pos := components[index].position
        vel := components[index].velocity
        new_pos := pos + vel * dt
        components[index].position = new_pos

        if (entity_type == .Ufo_Small || entity_type == .Ufo_Big) && is_out_of_bounds_x(new_pos) {
            append(&entities_to_destroy_behavioral, index)
        } 

        // Wraparound
        if new_pos.x <= f32(play_edge_left()) {
            dx := f32(play_edge_left()) - new_pos.x
            components[index].position = {f32(play_edge_right()) - dx, new_pos.y}
        } else if new_pos.x >= f32(play_edge_right()) {
            dx := new_pos.x - f32(play_edge_right())
            components[index].position = {f32(play_edge_left()) + dx, new_pos.y}
        }
        if new_pos.y <= f32(play_edge_top()) {
            dy := f32(play_edge_top()) - new_pos.y
            components[index].position = {new_pos.x, f32(play_edge_bottom()) - dy}
        } else if new_pos.y >= f32(play_edge_bottom()) {
            dy := new_pos.y - f32(play_edge_bottom())
            components[index].position = {new_pos.x, f32(play_edge_top()) + dy}
        }
    }
    for index_to_destroy in entities_to_destroy_behavioral {
        if components[index_to_destroy].shooter == .Ship {
            g_mem.ship_active_bullets -= 1
        }
        destroy_entity(index_to_destroy)
    }
}

handle_collisions :: proc() {
    n_active_entities := get_active_entity_count()

    entities_to_destroy: [dynamic]int // uses index
    defer delete(entities_to_destroy)
    asteroids_to_spawn: [dynamic]Spawn_Asteroid_Data
    defer delete(asteroids_to_spawn)

    for index_a in 0..<n_active_entities-1 {
        // skip if a destroyed
        is_destroyed_a := false
        for id in entities_to_destroy {
            if index_a == id {
                is_destroyed_a = true
                break
            }
        }
        if is_destroyed_a do continue

        for index_b in (index_a + 1)..<n_active_entities {
            // skip if b destroyed
            is_destroyed_b := false
            for id in entities_to_destroy {
                if index_b == id {
                    is_destroyed_b = true
                    break
                }
            }
            if is_destroyed_b do continue

            pos_a := components[index_a].position
            pos_b := components[index_b].position
            radius_a := components[index_a].radius
            radius_b := components[index_b].radius

            if !rl.CheckCollisionCircles(pos_a, radius_a, pos_b, radius_b) {
                continue
            }

            // check is pair of entities specified, return as such
            type_a := components[index_a].type
            type_b := components[index_b].type

            is_some_ship := type_a == .Ship || type_b == .Ship
            is_some_bullet := type_a == .Bullet || type_b == .Bullet

            // Ship collisions
            if is_some_ship && g_mem.ship_state == .Normal {
                is_type_a_ship := type_a == .Ship
                other_index := is_type_a_ship ? index_b : index_a
                other_type := is_type_a_ship ? type_b : type_a

                switch other_type {
                case .Asteroid_Large, .Asteroid_Medium, .Asteroid_Small:
                    aster_position := components[other_index].position
                    kill_asteroid(&asteroids_to_spawn, &entities_to_destroy, other_type, other_index, .Ship,  aster_position)
                    kill_ship()
                case .Ufo_Big, .Ufo_Small:
                    ufo_position := components[other_index].position
                    kill_ufo(&entities_to_destroy, other_type, other_index, ufo_position, .Ship)
                    kill_ship()
                case .Bullet:
                    if components[other_index].shooter == .Ship {
                        continue
                    } else {
                        append(&entities_to_destroy, other_index)
                        kill_ship()
                    }
                case .Ship, .None:
                }
                continue
            }

            is_some_asteroid: bool
            if type_a == .Asteroid_Large || 
                type_a == .Asteroid_Medium || 
                type_a == .Asteroid_Small || 
                type_b == .Asteroid_Large || 
                type_b == .Asteroid_Medium || 
                type_b == .Asteroid_Small {
                is_some_asteroid = true
            }

            // Collide bullet and asteroid
            if is_some_bullet && is_some_asteroid {
                is_type_a_bullet := type_a == .Bullet
                bullet_index := is_type_a_bullet ? index_a : index_b
                append(&entities_to_destroy, bullet_index)

                aster_index := is_type_a_bullet ? index_b : index_a
                aster_type := is_type_a_bullet ? type_b : type_a
                aster_position := components[aster_index].position
                shooter := components[bullet_index].shooter
                kill_asteroid(&asteroids_to_spawn, &entities_to_destroy, aster_type, aster_index, shooter,  aster_position)
                continue
            }

            is_some_ufo := type_a == .Ufo_Small || type_b == .Ufo_Small || type_a == .Ufo_Big || type_b == .Ufo_Big

            // Collide bullet and ufo
            if is_some_bullet && is_some_ufo {
                is_type_a_bullet := type_a == .Bullet
                bullet_index := is_type_a_bullet ? index_a : index_b
                ufo_index := is_type_a_bullet ? index_b : index_a
                ufo_type := is_type_a_bullet ? type_b : type_a
                ufo_position := components[ufo_index].position
                shooter := components[bullet_index].shooter
                if shooter == .Ship {
                    append(&entities_to_destroy, bullet_index)
                    kill_ufo(&entities_to_destroy, ufo_type, ufo_index, ufo_position, shooter)
                } 
                continue
            }

            if is_some_ufo && is_some_asteroid {
                is_type_a_ufo := type_a == .Ufo_Small || type_a == .Ufo_Big
                ufo_type := is_type_a_ufo ? type_a : type_b
                ufo_index := is_type_a_ufo ? index_a : index_b
                ufo_position := components[ufo_index].position
                aster_index := is_type_a_ufo ? index_b : index_a
                aster_type := is_type_a_ufo ? type_b : type_a
                aster_position := components[aster_index].position
                kill_ufo(&entities_to_destroy, ufo_type, ufo_index, ufo_position, .None)
                kill_asteroid(&asteroids_to_spawn, &entities_to_destroy, aster_type, aster_index, .None,  aster_position)
                continue
            }
        }
    }

    for index_to_destroy in entities_to_destroy {
        if components[index_to_destroy].shooter == .Ship {
            g_mem.ship_active_bullets -= 1
        }
        destroy_entity(index_to_destroy)
    }

    for data in asteroids_to_spawn {
        spawn_asteroid(data.type, data.pos, data.vel)
    }
}

kill_ship :: proc() {
    if !rl.IsSoundPlaying(g_mem.sounds[.Death]) {
        rl.PlaySound(g_mem.sounds[.Death])
    }
    components[get_player_index()].velocity = {}
    g_mem.lives -= 1
    g_mem.ship_state = .Death
}

kill_asteroid :: proc(asteroids_to_spawn: ^[dynamic]Spawn_Asteroid_Data, entities_to_destroy: ^[dynamic]int, type: Entity_Type, index: int, shooter: Shooter_Type, position: Vec2) {
    rl.PlaySound(g_mem.sounds[.Asteroid_Explode])
    #partial switch type {
    case .Asteroid_Small:
        if shooter == .Ship do increment_score(100)
    case .Asteroid_Medium:
        if shooter == .Ship do increment_score(50)
        vel := components[index].velocity
        vel_a := jiggle_asteroid_velocity(vel, 1.5)
        vel_b := jiggle_asteroid_velocity(vel, 1.5)
        vel_c := jiggle_asteroid_velocity(vel, 1.5)
        small_positions := spawn_positions_destroyed_medium_asteroid(position, vel)
        append(asteroids_to_spawn, Spawn_Asteroid_Data{ type = .Asteroid_Small, pos = small_positions[0], vel = vel_a})
        append(asteroids_to_spawn, Spawn_Asteroid_Data{ type = .Asteroid_Small, pos = small_positions[1], vel = vel_b})
        append(asteroids_to_spawn, Spawn_Asteroid_Data{ type = .Asteroid_Small, pos = small_positions[2], vel = vel_c})
    case .Asteroid_Large:
        if shooter == .Ship do increment_score(20)
        vel := components[index].velocity
        vel_a := jiggle_asteroid_velocity(vel)
        vel_b := jiggle_asteroid_velocity(vel)
        med_positions := spawn_positions_destroyed_large_asteroid (position, vel)
        append(asteroids_to_spawn, Spawn_Asteroid_Data{ type = .Asteroid_Medium, pos = med_positions[0], vel = vel_a})
        append(asteroids_to_spawn, Spawn_Asteroid_Data{ type = .Asteroid_Medium, pos = med_positions[1], vel = vel_b})
    }
    append(entities_to_destroy, index)
}

kill_ufo :: proc (entities_to_destroy: ^[dynamic]int, ufo_type: Entity_Type, ufo_index: int, ufo_position: Vec2, shooter: Shooter_Type) {
    rl.PlaySound(g_mem.sounds[.Asteroid_Explode])
    if shooter == .Ship {
        if ufo_type == .Ufo_Big {
            increment_score(200)
        } else if ufo_type == .Ufo_Small {
            increment_score(500)
        }
    }
    append(entities_to_destroy, ufo_index)
}

draw_asteroid :: proc(pos: Vec2, rot: f32, radius: f32) {
    rl.DrawPolyLines(pos, N_ASTEROID_SIDES, radius, rot, rl.RAYWHITE)
}

get_score :: proc() -> i32 {
    return g_mem.score
}

draw_ui :: proc() {
    sw := f32(rl.GetScreenWidth())
    sh := f32(rl.GetScreenHeight())
    if g_mem.game_state == .Intro {
        rl.DrawText(
            fmt.ctprint("Thruster = W/Up\n\nRotate = A,D/Left,Right arrows\n\nFire = Space\n\nTeleport = Shift"),
            i32(sw * 3 / 8), i32(sh * 3 / 5), 30, rl.RAYWHITE,
        )
    }
    rl.DrawText(fmt.ctprintf("%v", get_score()), i32(sw * 2 / 8), i32(sh / 15), 42, rl.RAYWHITE)
    for i in 0..<g_mem.lives {
        draw_ship({(sw * 2 / 8) + f32(i) * (SHIP_R * 1.7), sh / 7}, math.to_radians(f32(-90)), 0.75)
    }
    if g_mem.game_state == .Game_Over {
        rl.DrawText(
            fmt.ctprint("GAME OVER\n\nHit Space to play again"),
            i32(sw * 3 / 8), i32(sh / 2), 40, rl.RAYWHITE,
        )
    }
}

draw_debug_ui :: proc() {
    vel := components[get_player_index()].velocity
    speed := linalg.length(vel)
    if DEBUG {
        rl.DrawText(
            fmt.ctprintf(
                "fps: %v\nwin: %vx%v\nlogical: %vx%v\ndt: %v\ndt_running: %v\npos: %v\nvel: %v\nspeed: %v\nactive_entities: %v\nentities: %v\nfree_list: %v\ngame_state: %v\nship_state: %v\nship_active_bulet: %v",
                rl.GetFPS(),
                rl.GetScreenWidth(),
                rl.GetScreenHeight(),
                LOGICAL_H,
                LOGICAL_W,
                rl.GetFrameTime(),
                rl.GetTime(),
                components[0].position,
                vel,
                speed,
                get_active_entity_count(),
                sa.slice(&g_mem.entities)[:get_active_entity_count()],
                sa.slice(&g_mem.free_list)[:sa.len(g_mem.free_list)],
                g_mem.game_state,
                g_mem.ship_state,
                g_mem.ship_active_bullets,
            ),
            3, 3, 12, rl.RAYWHITE,
        )
        rl.DrawText(
            fmt.ctprintf(
                "cam.tar: %v\ncam.off: %v\nscreen_left: %v\nscreen_right: %v\nplay_area_top: %v\nplay_area_bot:%v\nplay_area_left: %v\nplay_area_right: %v",
                game_camera().target,
                game_camera().offset,
                screen_left(),
                screen_right(),
                play_edge_top(),
                play_edge_bottom(),
                play_edge_left(),
                play_edge_right(),
            ),
            i32(rl.GetScreenWidth() - 210), 3, 12, rl.RAYWHITE,
        )
    }
}

get_player_id :: proc() -> Entity_Id {
	return g_mem.player_id
}

get_player_index :: proc() -> int {
	index, ok := g_mem.manager.entity_to_index[g_mem.player_id]
	if !ok {
        log.warn("Player entity id not in entity_to_index map")
        return -1
	}
    return index
}

get_entity_id :: proc(index: int) -> Entity_Id {
    return sa.get(g_mem.manager.entities, index)
}

screen_left :: proc() -> f32 {
	return -LOGICAL_W / 2
}
screen_right :: proc() -> f32 {
	return LOGICAL_W / 2
}
screen_top :: proc() -> f32 {
	return -LOGICAL_H / 2
}
screen_bottom :: proc() -> f32 {
	return LOGICAL_H / 2
}

pr_span :: proc(msg: Maybe(string)) {
    pr("-----------------------", msg.? or_else "", "-----------------------")
}

angle_radians_to_vec :: proc(rot: f32) -> Vec2 {
    return Vec2{math.cos(rot), math.sin(rot)}
}

load_sound_from_kind :: proc(kind: Sound_Kind) -> rl.Sound {
    base_path := "assets/audio/"
    file: string
    switch kind {
	case .Fire:
        file = "shot-light.wav"
    case .Thrust:
        file = "thrust.wav"
    case .Score:
        file = "score.wav"
    case .Bullet_Impact:
        file = "moderate-thud.wav"
    case .Asteroid_Explode:
        file = "destroy-asteroid.wav"
    case .Death:
        file = "physical-death.wav"
    case .Beat_Lo:
        file = "beat-low.wav"
    case .Beat_Hi:
        file = "beat-hi.wav"
    case .Ufo_Alarm:
        file = "ufo-alarm.wav"
	}
    path := fmt.ctprintf("%v%v", base_path, file)
    return rl.LoadSound(path)
}

increment_score :: proc(x: i32) {
    g_mem.score += x
}

get_extra_life_count:: proc() -> i32 {
    return g_mem.extra_life_count
}

increment_extra_life_count :: proc() {
    g_mem.extra_life_count += 1
    g_mem.lives += 1
}

jiggle_asteroid_velocity :: proc(vel: Vec2, multiplier: f32 = 1) -> Vec2 {
    speed := linalg.length(vel)
    d_speed :f32= (speed + 10) * 0.1
    jiggled_speed := rand.float32_range(10 + d_speed, 10 + d_speed + speed) * multiplier

    // scatter omnidirectionally, instead of biased around 0 (aka East)
    angle_jiggle_range : f32 = speed == 0 ? 180 : 30

    unit_direction: Vec2
    if speed == 0 {
        x := rand.float32_range(-1, 1)
        y := rand.float32_range(-1, 1)
        unit_direction = linalg.normalize0(Vec2{x, y})
    } else {
        unit_direction = linalg.normalize0(vel)
    }
    d_rotation := rand.float32_range(-angle_jiggle_range, angle_jiggle_range)
    jiggled_direction := rotate_vector(unit_direction, d_rotation)

    jiggled_velocity := jiggled_direction * jiggled_speed
    return jiggled_velocity
}

// angle deg
rotate_vector :: proc(v: Vec2, deg: f32) -> Vec2 {
    deg := deg
    deg = math.to_radians(deg)
    x := v.x * math.cos(deg) - v.y * math.sin(deg)
    y := v.x * math.sin(deg) + v.y * math.cos(deg)
    return {x,y}
}

spawn_positions_destroyed_medium_asteroid :: proc(pos: Vec2, vel: Vec2) -> [3]Vec2 {
    positions: [3]Vec2
    unit_direction := linalg.normalize0(vel) // doesnt crash on zero vector
    if linalg.length(unit_direction) == 0 {
        // extremely rare, if at all possible to get 2 rand values of 0.0
        unit_direction = make_random_direction()
    }
    d_pos :f32= 12
    d_angle :f32= 120
    positions[0] = pos + (unit_direction * d_pos)
    positions[1] = pos + (rotate_vector(unit_direction, d_angle) * d_pos)
    positions[2] = pos + (rotate_vector(unit_direction, -d_angle) * d_pos)
    return positions
}

spawn_positions_destroyed_large_asteroid :: proc(pos: Vec2, vel: Vec2) -> [2]Vec2 {
    positions: [2]Vec2
    unit_direction := linalg.normalize0(vel) // doesnt crash on zero vector
    if linalg.length(unit_direction) == 0 {
        // extremely rare, if at all possible to get 2 rand values of 0.0
        unit_direction = make_random_direction()
    }
    d_pos :f32= 30
    d_angle :f32= 90
    positions[0] = pos + rotate_vector(unit_direction, d_angle) * d_pos
    positions[1] = pos + rotate_vector(unit_direction, -d_angle) * d_pos
    return positions
}

make_random_direction :: proc() -> Vec2 {
    x := rand.float32_range(-1, 1)
    y := rand.float32_range(-1, 1)
    return linalg.normalize0(Vec2{x, y})
}

tick_timer :: proc (timer: ^Timer, dt: f32) {
    timer.accum -= dt
}

restart_timer :: proc(timer: ^Timer) {
    timer.accum = timer.interval
}

clear_timer :: proc(timer: ^Timer) {
    timer.accum = 0
}

is_timer_done :: proc(timer: Timer) -> bool {
    return timer.accum <= 0
}

update_beat_sound_timer_with_level :: proc(beat_level: i32) {
    g_mem.beat_sound_timer.interval = INIT_TIMER_INTERVAL_BEAT_SOUND * math.pow(0.86, f32(beat_level))
}

is_out_of_bounds :: proc(pos: Vec2) -> bool {
    return pos.x < f32(play_edge_left()) || pos.x > f32(play_edge_right()) || pos.y < f32(play_edge_top()) || pos.y > f32(play_edge_bottom())
}

is_out_of_bounds_x :: proc(pos: Vec2) -> bool {
    return pos.x < f32(play_edge_left()) || pos.x > f32(play_edge_right())
}

process_ufo_move :: proc(index: int, dt: f32, move_timer: Timer, vel: Vec2, type: Entity_Type) {
    move_timer := move_timer
    if process_timer(&move_timer) {
        chance_to_move : f32 = type == .Ufo_Big ? BIG_UFO_CHANCE_TO_MOVE : SMALL_UFO_CHANCE_TO_MOVE
        rgn := rand.float32()
        if rgn < chance_to_move {
            speed: f32
            if type == .Ufo_Big {
                speed = BIG_UFO_SPEED
            } else if type == .Ufo_Small {
                speed = SMALL_UFO_SPEED
            }
            // bias direction to level flight. direction based on ratio, avoid rolling again
            // 75% level, 12.5 up/down
            if rgn < chance_to_move * 0.75 {
                new_vel := vel.x >= 0 ? Vec2{speed, 0} : Vec2{-speed, 0 }
                components[index].velocity = new_vel

            // up diag
            } else if rgn < chance_to_move * 0.875 {
                dir := vel.x >= 0 ? Vec2{1, -1} : Vec2{-1, -1}
                new_vel :=  dir * speed
                components[index].velocity = new_vel

            // down diag
            } else if rgn < chance_to_move {
                dir := vel.x >= 0 ? Vec2{1, 1} : Vec2{-1, 1}
                new_vel :=  dir * speed
                components[index].velocity = new_vel
            }
        }
    }
    components[index].move_timer = move_timer
}

process_ufo_shot :: proc(index: int, dt: f32, shot_timer: Timer, type: Entity_Type, ufo_pos: Vec2) {
    shot_timer := shot_timer
    if process_timer(&shot_timer) {
        chance_to_shoot : f32 = type == .Ufo_Big ? BIG_UFO_CHANCE_TO_SHOOT : SMALL_UFO_CHANCE_TO_SHOOT
        rgn := rand.float32()
        if rgn < chance_to_shoot {

            // Shot direction
            player_pos := components[get_player_index()].position
            shot_dir: Vec2
            if type == .Ufo_Big {
                rgn_dir := rand.float32()
                angle_radians := 2 * math.PI * rgn_dir
                shot_dir = {math.cos(angle_radians), math.sin(angle_radians)}
            } else if type == .Ufo_Small {
                d_pos := player_pos - ufo_pos
                shot_dir = linalg.normalize0(d_pos)
            }

            spawn_bullet(ufo_pos, shot_dir * BULLET_SPEED, .Ufo)
            rl.PlaySound(g_mem.sounds[.Fire])
        }
    }
    components[index].shot_timer = shot_timer
}

spawn_bullet :: proc(pos: Vec2, vel: Vec2, shooter: Shooter_Type) {
    id := create_entity(.Bullet)
    data_in := Big_Component{
        type = .Bullet,
        position = pos,
        velocity = vel,
        lifespan = BULLET_LIFESPAN,
        shooter = shooter,
        radius = BULLET_PHYSICS_RADIUS,
    }
    set_component_data(id, data_in)
}

// Reset component values
reset_entity_components :: proc(index: int) {
    components[index] = {}
}

set_game_over :: proc() {
    g_mem.game_state = .Game_Over
}

eval_game_over :: proc() {
    if rl.IsKeyPressed(.V) && DEBUG {
        set_game_over()
    }
    if g_mem.game_state == .Game_Over {
        if rl.IsKeyPressed(.SPACE) || g_mem.is_gesture_tap {
            reset_gameplay_data()
        }
    }
}

process_timer :: proc(timer: ^Timer) -> (is_done: bool) {
    tick_timer(timer, rl.GetFrameTime())
    if is_timer_done(timer^) {
        restart_timer(timer)
        return true
    }
    return false
}

spawn_ship :: proc(pos: Vec2, rot: f32) -> Entity_Id {
    id := create_entity(.Ship)
    set_component_data(id, Big_Component{
        type = .Ship,
        position = pos,
        rotation = rot,
        velocity = Vec2{0, 0},
        radius = SHIP_R,
    })
    return id
}

spawn_asteroid :: proc(entity_type: Entity_Type, pos: Vec2, vel: Vec2) {
    id := create_entity(entity_type)
    visual_rotation_rate := rand.float32_range(-2, 2)
    radius: f32
    #partial switch entity_type {
    case .Asteroid_Small:
        radius = SMALL_ASTEROID_RADIUS
    case .Asteroid_Medium:
        radius = MEDIUM_ASTEROID_RADIUS
    case .Asteroid_Large:
        radius = LARGE_ASTEROID_RADIUS
    }
    data_in := Big_Component{
        type = entity_type,
        position = pos,
        velocity = vel,
        radius = radius,
        visual_rotation_rate = visual_rotation_rate,
    }
    set_component_data(id, data_in)
}

spawn_bullet_from_ship :: proc() {
    player_index := get_player_index()

    ship_rotation := components[player_index].rotation
    rotation_vector := angle_radians_to_vec(ship_rotation)
    ship_position := components[player_index].position

    bullet_position := ship_position + rotation_vector * SHIP_R
    velocity := rotation_vector * BULLET_SPEED

    g_mem.ship_active_bullets += 1
    spawn_bullet(bullet_position, velocity, .Ship)
}

spawn_ufo :: proc(entity_type: Entity_Type, pos: Vec2, is_moving_right: bool) {
    id := create_entity(entity_type)
    radius: f32
    move_timer: Timer
    shot_timer: Timer
    speed: f32
    #partial switch entity_type {
    case .Ufo_Big:
        radius = BIG_UFO_RADIUS
        move_timer = Timer{
            interval = TIMER_INTERVAL_UFO_BIG_MOVE,
            accum = TIMER_INTERVAL_UFO_BIG_MOVE,
        }
        shot_timer = Timer{
            interval = TIMER_INTERVAL_UFO_BIG_SHOOT,
            accum = TIMER_INTERVAL_UFO_BIG_SHOOT,
        }
        speed = BIG_UFO_SPEED
    case .Ufo_Small:
        radius = SMALL_UFO_RADIUS
        move_timer = Timer{
            interval = TIMER_INTERVAL_UFO_SMALL_MOVE,
            accum = TIMER_INTERVAL_UFO_SMALL_MOVE,
        }
        shot_timer = Timer{
            interval = TIMER_INTERVAL_UFO_SMALL_SHOOT,
            accum = TIMER_INTERVAL_UFO_SMALL_SHOOT,
        }
        speed = SMALL_UFO_SPEED
    }
    data_in := Big_Component{
        type = entity_type,
        position = pos,
        velocity = is_moving_right ? Vec2{speed,0} : Vec2{-speed,0},
        radius = radius * 0.8,
        move_timer = move_timer,
        shot_timer = shot_timer,
    }
    set_component_data(id, data_in)
}
