package game

import "core:fmt"
import rl "vendor:raylib"
import sa "core:container/small_array"
import math "core:math"
import linalg "core:math/linalg"
import rand "core:math/rand"

pr :: fmt.println
Vec2 :: rl.Vector2

DEBUG :: false
WINDOW_W :: 1000
WINDOW_H :: 750
LOGICAL_W :: 1000
LOGICAL_H :: 750

PHYSICS_HZ :: 120
FIXED_DT :: 1 / PHYSICS_HZ

TIMER_INTERVAL_INTRO_MESSAGE :: 0.5

MAX_ENTITIES :: 128
N_ASTEROID_SIDES :: 8
SMALL_ASTEROID_RADIUS :: 15

SHIP_R :: 22
SHIP_ROTATION_MAGNITUDE :: 5
SHIP_MAX_SPEED :: 350
THRUST_MAGNITUDE :: 6
SPACE_FRICTION_COEFFICIENT :: 0.01 // cause of plasma and charged dust
TIMER_INTERVAL_THRUST_DRAW :: 0.075

TIMER_INTERVAL_TELEPORT :: 1
TIMER_INTERVAL_DEATH :: 1
TIMER_INTERVAL_SPAWN :: 2
TIMER_INTERVAL_BETWEEN_LEVELS :: 2

SHIP_BULLET_COUNT_LIMIT :: 4
BULLET_SPEED :: 500
BULLET_LIFESPAN_SPEED_RATIO :: 0.0018
BULLET_LIFESPAN :: BULLET_SPEED * BULLET_LIFESPAN_SPEED_RATIO
BULLET_PHYSICS_RADIUS :: 1

BIG_UFO_RADIUS :: 25
BIG_UFO_SPEED :: 150
TIMER_INTERVAL_UFO_BIG_MOVE :: 0.5
BIG_UFO_CHANCE_TO_MOVE :: 1
TIMER_INTERVAL_UFO_BIG_SHOOT :: 1
BIG_UFO_CHANCE_TO_SHOOT :: 0.4

SMALL_UFO_RADIUS :: 15
SMALL_UFO_SPEED :: 165
TIMER_INTERVAL_UFO_SMALL_MOVE :: 0.2
SMALL_UFO_CHANCE_TO_MOVE :: 1
TIMER_INTERVAL_UFO_SMALL_SHOOT :: 0.75
SMALL_UFO_CHANCE_TO_SHOOT :: .5

TIMER_INTERVAL_BEAT :: 12
TIMER_INTERVAL_UFO :: 5
INIT_TIMER_INTERVAL_BEAT_SOUND :: 1

Game_Memory :: struct {
	player_id: Entity_Id,
	run: bool,
	using manager: ^Entity_Manager,
    sounds: [Sound_Kind]rl.Sound,
    score: i32,
    lives: i32,
    extra_life_count: i32,
    ship_state: Ship_State,
    death_timer: Timer,
    spawn_timer: Timer,
    between_levels_timer: Timer,
    game_state: Game_State,
    beat_level: i32,
    beat_level_timer: Timer,
    ufo_timer: Timer,
    beat_sound_timer: Timer,
    is_beat_sound_hi: bool,
    thrust_draw_timer: Timer,
    is_thrust_drawing: bool,
    ship_active_bullets: i32,
    teleport_timer: Timer,
    level: i32,
    intro_timer: Timer,
}

touch_pos: Vec2
touch_area: rl.Rectangle
gestures_count: i32
gesture_strings: [12]rune
current_gesture: rl.Gestures
last_gesture: rl.Gestures

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

g_mem: ^Game_Memory
sounds: ^[Sound_Kind]rl.Sound
entity_m: ^Entity_Manager
ship_state: ^Ship_State
game_state: ^Game_State

Sound_Kind :: enum {
    Fire,
    Harm,
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
	entities: sa.Small_Array(MAX_ENTITIES, Entity_Id), // len used as active_entity_count, order doesn't align with components
	free_list: sa.Small_Array(MAX_ENTITIES, Entity_Id),
	types: [MAX_ENTITIES]Entity_Type, // CSDR moving this under gameplay or other?? the data flow (set/get) is disjointed
	entity_to_index: map[Entity_Id]int,

	using physics: ^Physics_Data,
	using rendering: ^Rendering_Data,
	using gameplay: ^Gameplay_Data,
}

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

Physics_Data :: struct {
	positions: [MAX_ENTITIES]Vec2,
	velocities: [MAX_ENTITIES]Vec2,
	rotations: [MAX_ENTITIES]f32,
	masses: [MAX_ENTITIES]f32,
	radii_physics: [MAX_ENTITIES]f32,
}

Gameplay_Data :: struct {
    damages: [MAX_ENTITIES]i32,
    healths: [MAX_ENTITIES]i32,
	lifespans: [MAX_ENTITIES]f32,
    shot_timers: [MAX_ENTITIES]Timer,
    move_timers: [MAX_ENTITIES]Timer,
    shooters: [MAX_ENTITIES]Shooter_Type,
}

Shooter_Type :: enum {
    None,
    Ship,
    Ufo,
}

MAX_RENDER_VERTICES :: 8
Render_Vertices_Component :: [MAX_RENDER_VERTICES]Vec2
Rendering_Data :: struct {
	types_render: [MAX_ENTITIES]Render_Type,
	vertices: [MAX_ENTITIES]Render_Vertices_Component,
	radii_render: [MAX_ENTITIES]f32,
	colors: [MAX_ENTITIES]rl.Color,
	visual_rotation_rates: [MAX_ENTITIES]f32, // asteroid visual rotation
	is_visibles: [MAX_ENTITIES]bool,
	scales: [MAX_ENTITIES]f32,
}

Render_Type :: enum {
    None,
	Ship,
	Asteroid,
	Bullet,
	Particle,
    Ufo_Big,
    Ufo_Small,
}

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

set_game_over :: proc() {
    game_state^ = .Game_Over
}

eval_game_over :: proc() {
    if rl.IsKeyPressed(.V) && DEBUG {
        set_game_over()
    }
    if game_state^ == .Game_Over {
        if rl.IsKeyPressed(.SPACE) {
            reset_gameplay_data()
        }
    }
}

update :: proc() {
	if rl.IsKeyPressed(.ESCAPE) {
		g_mem.run = false
	}

    eval_game_over()
    if game_state^ == .Game_Over do return

    dt := rl.GetFrameTime()

    if g_mem.game_state == .Intro {
        tick_timer(&g_mem.intro_timer, dt)
        if is_timer_done(g_mem.intro_timer) {
            g_mem.game_state = .Between_Levels
            restart_timer(&g_mem.intro_timer)
        }
        return
    }


    update_entities(entity_m, dt)
    handle_collisions(g_mem.manager)

    // lifespans
    bullets_with_expired_lifespans: [dynamic]int
    defer delete(bullets_with_expired_lifespans)
    for index in 0..<get_active_entity_count(g_mem.manager^) {
        type := get_entity_type(g_mem.manager, index)
        if type == .Bullet {
            lifespan := get_lifespan(g_mem.manager, index)
            new_lifespan := lifespan - dt
            if new_lifespan <= 0 {
                append(&bullets_with_expired_lifespans, index)
            } else {
                set_lifespan(g_mem.manager, index, new_lifespan)
            }
        }
    }
    for index in bullets_with_expired_lifespans {
        id := sa.get(g_mem.manager.entities, index)
        shooter := get_shooter(g_mem.manager, index)
        if shooter == .Ship {
            g_mem.ship_active_bullets -= 1
        }
        destroy_entity(g_mem.manager, id)
    }

    if get_score() > (get_extra_life_count() + 1) * 10000 {
        increment_extra_life_count()
    }

    // The pause between levels, then spawn the level
    count := get_asteroid_count(entity_m^)
    if count == 0 && game_state^ == .Play {
        game_state^ = .Between_Levels
    } else if game_state^ == .Between_Levels {
        tick_timer(&g_mem.between_levels_timer, dt)
        if is_timer_done(g_mem.between_levels_timer) {
            game_state^ = .Play
            restart_timer(&g_mem.between_levels_timer)
            restart_timer(&g_mem.beat_level_timer)
            restart_timer(&g_mem.beat_sound_timer)
            g_mem.beat_level = 1
            update_beat_sound_timer_with_level(1)
            spawn_level(entity_m)
        }
    }

    // Update beat levels
    tick_timer(&g_mem.beat_level_timer, dt)
    if is_timer_done(g_mem.beat_level_timer) {
        g_mem.beat_level = clamp(g_mem.beat_level + 1, 1, 4)
        update_beat_sound_timer_with_level(g_mem.beat_level)
        restart_timer(&g_mem.beat_level_timer)
    }

    // Play beat sound IAW beat level
    tick_timer(&g_mem.beat_sound_timer, dt)
    if is_timer_done(g_mem.beat_sound_timer) {
        if g_mem.is_beat_sound_hi {
            rl.PlaySound(sounds[.Beat_Hi])
        } else {
            rl.PlaySound(sounds[.Beat_Lo])
        }
        restart_timer(&g_mem.beat_sound_timer)
        g_mem.is_beat_sound_hi = !g_mem.is_beat_sound_hi
    }

    // Spawn Ufos
    spawner_ufo(g_mem.beat_level, dt)
}

spawner_ufo :: proc(beat_level: i32, dt: f32) {
    tick_timer(&g_mem.ufo_timer, dt)
    if !is_timer_done(g_mem.ufo_timer) {
        return
    }
    restart_timer(&g_mem.ufo_timer)

    base_chance_big :: 0.1
    big_spawn_factor := base_chance_big * (1 + f32(beat_level) * 0.07)

    // 1/5 chance to spawn small at beat_level == 1
    base_chance_small :: 0.025
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
        spawn_ufo(spawn_ufo_type, {pos_x, pos_y}, true, entity_m)
    } else {
        // spawn right wall
        pos_y := ((rgn_pos - 1) * span_y * 0.8) + (span_y * 0.1) - (span_y / 2)
        pos_x := f32(play_edge_right())
        spawn_ufo(spawn_ufo_type, {pos_x, pos_y}, false, entity_m)
    }
}

spawn_ufo :: proc(entity_type: Entity_Type, pos: Vec2, is_moving_right: bool, entity_m: ^Entity_Manager) {
    id := create_entity(entity_m, entity_type)
    radius: f32
    move_timer: Timer
    shot_timer: Timer
    speed: f32
    render_type: Render_Type
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
        render_type = .Ufo_Big
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
        render_type = .Ufo_Small
    }
    data_in := Component_Data{
        position = pos,
        velocity = is_moving_right ? Vec2{speed,0} : Vec2{-speed,0},
        radius_physics = radius * 0.8,
        render_type = render_type,
        color = rl.RAYWHITE,
        radius_render = radius,
        health = 1,
        is_visible = true,
        move_timer = move_timer,
        shot_timer = shot_timer,
    }
    set_component_data(entity_m, id, data_in)

}

get_asteroid_count :: proc(entity_m: Entity_Manager) -> i32 {
    count : i32 = 0
    for i in 0..<get_active_entity_count(entity_m) {
        if entity_m.types[i] == .Asteroid_Large || entity_m.types[i] == .Asteroid_Medium || entity_m.types[i] == .Asteroid_Small {
            count += 1
        }
    }
    return count
}

spawn_level :: proc(entity_m: ^Entity_Manager) {
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
        spawn_asteroid(.Asteroid_Large, pos, vel, entity_m)
    }
    g_mem.level += 1
}

draw :: proc() {
	rl.BeginDrawing()
	rl.ClearBackground(rl.BLACK)

	rl.BeginMode2D(game_camera())
    draw_screen_edges()
	draw_entities(entity_m) 
	rl.EndMode2D()

	rl.BeginMode2D(ui_camera())
	draw_debug_ui()
    draw_ui()
	rl.EndMode2D()

	rl.EndDrawing()
}

// Screen edges are all within play area. The drawn boundary line currently within of play area
// TODO: make boundary line (draw_screen_edges) outside of play area
// more aptly named, play_edge_left/top...
// screen_left/top/right/bot should be the actual boundary lines
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
    rl.DrawRectangleLines(i32(screen_left()), i32(screen_top() + 1), LOGICAL_W, LOGICAL_H - 2, rl.RAYWHITE)
}

@(export)
game_update :: proc() {
	update()
	draw()
}

@(export)
game_init_window :: proc() {
    // .Borderlesswindowedmode, .fullscreen_mode, window_maximized
	rl.SetConfigFlags({.VSYNC_HINT,  .WINDOW_RESIZABLE, .WINDOW_MAXIMIZED})
	rl.InitWindow(WINDOW_W, WINDOW_H, "Asteroids")
	rl.SetWindowPosition(50, 150)
	rl.SetTargetFPS(60)
	rl.SetExitKey(nil)
    rl.InitAudioDevice()
}

@(export)
game_init :: proc() {
	pr_span("IN game_init")
	g_mem = new(Game_Memory)

	manager := new(Entity_Manager)
	physics := new(Physics_Data)
	rendering := new(Rendering_Data)
	gameplay := new(Gameplay_Data)
	manager.physics = physics
	manager.rendering = rendering
	manager.gameplay = gameplay

    for sound_kind in Sound_Kind {
        g_mem.sounds[sound_kind] = load_sound_from_kind(sound_kind)
    }
    g_mem.manager = manager
	g_mem.run = true
    g_mem.ship_state = .Normal
    g_mem.game_state = .Intro
    g_mem.lives = 3
    g_mem.level = 1
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
    g_mem.beat_level = 1
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

    sounds = &g_mem.sounds
    entity_m = g_mem.manager
    ship_state = &g_mem.ship_state
    game_state = &g_mem.game_state

	player_id := spawn_ship({0,0}, math.to_radians(f32(-90)), g_mem.manager)
    g_mem.player_id = player_id

    // spawn_asteroid(.Asteroid_Small, {140, 200}, {-20, -100}, g_mem.manager)

    // spawn_asteroid(.Asteroid_Small, {-50, 100}, {0, -100}, g_mem.manager)
    // spawn_asteroid(.Asteroid_Medium, {-100, 100}, {0, -100}, g_mem.manager)
    // spawn_asteroid(.Asteroid_Large, {-200, 100}, {0, -100}, g_mem.manager)
    //
    // spawn_asteroid(.Asteroid_Small, {0, -50}, {0, 0}, g_mem.manager)
    // spawn_asteroid(.Asteroid_Medium, {0, -100}, {0, 0}, g_mem.manager)
    // spawn_asteroid(.Asteroid_Large, {0, -200}, {0, 0}, g_mem.manager)
    touch_area = {0, 0, f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight())} // why the unusual height (resized to full?)

	game_hot_reloaded(g_mem)
	pr_span("END game_init")
}


// Here you can also set your own global variables. A good idea is to make
// your global variables into pointers that point to something inside
// `g_mem`.
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
game_shutdown_window :: proc() { rl.CloseWindow() }
@(export)
game_memory :: proc() -> rawptr { return g_mem }
@(export)
game_memory_size :: proc() -> int { return size_of(Game_Memory) }
@(export)
game_force_reload :: proc() -> bool { return rl.IsKeyPressed(.F6) || rl.IsKeyPressed(.R) }
@(export)
game_force_restart :: proc() -> bool { return rl.IsKeyPressed(.F7) }

// In a web build, this is called when browser changes size. Remove the
// `rl.SetWindowSize` call if you don't want a resizable game.
game_parent_window_size_changed :: proc(w, h: int) {
	rl.SetWindowSize(i32(w), i32(h))
}

draw_entities :: proc(manager: ^Entity_Manager) {
    dt := rl.GetFrameTime()
    for index in 0..<get_active_entity_count(manager^) {
        if !manager.is_visibles[index] do continue

        pos := get_position(manager, index)
        rot := get_rotation(manager, index)
        color := get_color(manager, index)

        switch get_render_type(manager, index) {
        case .Ship:
            vertices := get_vertices(manager,index)
            scale := get_scale(manager, index)
            switch ship_state^ {
            case .Normal:
                draw_ship(pos, rot, scale)
                if g_mem.is_thrust_drawing {
                    draw_ship_thruster(pos, rot, scale)
                }
            case .Death:
                draw_ship_death(pos)
            case .Spawning:
                draw_ship_spawning(pos, rot, vertices, color, dt, scale)
            case .Teleporting:
            }
        case .Asteroid:
            radius := get_radius_physics(manager, index)
            draw_asteroid(pos, rot, radius, get_color(manager, index))
        case .Bullet:
            draw_bullet(pos, color)
        case .Particle:
            rl.DrawCircleV(pos, 1.0, color)
        case .Ufo_Big:
            draw_ufo(pos, color, .Ufo_Big)
            physics_radius := get_radius_physics(manager, index)
            if DEBUG do rl.DrawCircleLinesV(pos, physics_radius, rl.BLUE)
        case .Ufo_Small:
            draw_ufo(pos, color, .Ufo_Small)
            physics_radius := get_radius_physics(manager, index)
            if DEBUG do rl.DrawCircleLinesV(pos, physics_radius, rl.BLUE)
        case .None:
        }
    }
}

draw_ufo :: proc(pos: Vec2, color: rl.Color, render_type: Render_Type) {
    is_ufo_big := render_type == .Ufo_Big
    r :f32= is_ufo_big ? BIG_UFO_RADIUS : SMALL_UFO_RADIUS
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

    offset := Vec2{0, 1} // fit better within collision circle
    d_pos := pos + offset
    for i in 0..<len(outline_vertices) - 1 {
        rl.DrawLineV(outline_vertices[i] + d_pos, outline_vertices[i+1] + d_pos, rl.RAYWHITE)
    }
    body_line := [?]Vec2{
        {-b, 0},
        {b, 0},
    }
    rl.DrawLineV(body_line[0] + d_pos, body_line[1] + d_pos, rl.RAYWHITE)

    canopy_line := [?]Vec2{
        {-s1, -h1},
        {s1, -h1},
    }
    rl.DrawLineV(canopy_line[0] + d_pos, canopy_line[1] + d_pos, rl.RAYWHITE)
}

draw_bullet :: proc(pos: Vec2, color: rl.Color) {
    rl.DrawRectangle(i32(pos.x), i32(pos.y), 3, 3, color)
}

draw_ship_spawning :: proc(pos: Vec2, rot: f32, vertices: Render_Vertices_Component, color: rl.Color, dt: f32, scale: f32) {
    @(static) blink_accum : f32 = 0.2
    @(static) is_visible := true
    blink_interval :f32= 0.2
    blink_accum -= dt
    if blink_accum <= 0 {
        is_visible = !is_visible
        blink_accum = blink_interval
    }
    if is_visible {
        draw_ship(pos, rot, scale)
    }
}

draw_ship_death :: proc(pos: Vec2) {
    start_positions := [?]Vec2{
        {10, 0},
        {5, 5},
        {0, 10},
        {-5, 5},
        {0, -10},
        {-5, -5},
        {-10, 0},
        {5, -5},
    }
    end_positions := [?]Vec2{
        {50, 0},
        {25, 25},
        {0,50},
        {-25, 25},
        {0,-50},
        {-25, -25},
        {-50, 0},
        {25, -25},
    }
    for i in 0..<len(start_positions) {
        t := (g_mem.death_timer.interval - g_mem.death_timer.accum) / g_mem.death_timer.interval
        pos_x := math.lerp(pos.x + start_positions[i].x, pos.x + end_positions[i].x, t)
        pos_y := math.lerp(pos.y + start_positions[i].y, pos.y + end_positions[i].y, t)
        rl.DrawPixelV({pos_x, pos_y}, rl.RAYWHITE)
    }
}

draw_ship :: proc(pos: Vec2, rot: f32, scale: f32 = 1) {
    r : f32 = SHIP_R * scale
    s : f32 = r * 1.63 // side length
    b : f32 = r * 0.25 // butt length
    nose_angle := math.to_radians(f32(32))

    // Body
    vertices: Render_Vertices_Component

     // nose
    vertices[0] = Vec2{r, 0}

    // sides
    vertices[1] =  Vec2{r - s * math.cos(nose_angle/2), -r * math.sin(nose_angle)} // left edge
    vertices[2] =  Vec2{r - s * math.cos(nose_angle/2), r * math.sin(nose_angle)} // right edge

     // butt
    b_half_y := (b + r) * math.tan(nose_angle/2) + 1 // add 1, pixel connecting butt to side may or may not render depending on s(?) or r
    vertices[3] = Vec2{-b, -b_half_y}
    vertices[4] = Vec2{-b, b_half_y}

    for &vertex in vertices[:5] {
        vertex = rotate_point(vertex, {0, 0}, rot) + pos
    }
    rl.DrawLineV(vertices[0], vertices[1], rl.RAYWHITE)
    rl.DrawLineV(vertices[0], vertices[2], rl.RAYWHITE)
    rl.DrawLineV(vertices[3], vertices[4], rl.RAYWHITE)

    if DEBUG do rl.DrawPixelV(pos, rl.RAYWHITE)
}

draw_ship_thruster :: proc(pos: Vec2, rot: f32, scale: f32 = 1) {
    r : f32 = SHIP_R * scale
    b : f32 = r * 0.25 // butt length
    t := b + (r * 0.5) // thrust exhaust length
    nose_angle := math.to_radians(f32(32))
    b_half_y := (b + r) * math.tan(nose_angle/2) + 1 // add 1, pixel connecting butt to side may or may not render depending on s(?) or r
    thrust_vertices: Render_Vertices_Component
    thrust_vertices[0] =  Vec2{-t, 0}
    thrust_vertices[1] = Vec2{-b, -(b_half_y * 0.6)}
    thrust_vertices[2] =  Vec2{-b, (b_half_y * 0.6)}
    for &vertex in thrust_vertices[:3] {
        vertex = rotate_point(vertex, {0, 0}, rot) + pos
    }
    rl.DrawLineV(thrust_vertices[0], thrust_vertices[1], rl.RAYWHITE)
    rl.DrawLineV(thrust_vertices[0], thrust_vertices[2], rl.RAYWHITE)
}

rotate_point :: proc(point: Vec2, center: Vec2, rot: f32 /* rad */) -> Vec2 {
    delta := point - center
    point_rotated := Vec2{
        delta.x * math.cos(rot) - delta.y * math.sin(rot) + center.x,
        delta.x * math.sin(rot) + delta.y * math.cos(rot) + center.y,
    }
    return point_rotated
}

get_last_entity_index :: proc(manager: Entity_Manager) -> int {
    return sa.len(manager.entities) - 1
}

get_active_entity_count :: proc(manager: Entity_Manager) -> int {
    return sa.len(manager.entities)
}

generate_entity_id :: proc(manager: Entity_Manager) -> Entity_Id {
    return Entity_Id(get_active_entity_count(manager))
}

create_entity :: proc(manager: ^Entity_Manager, type: Entity_Type) -> Entity_Id {
    index := get_active_entity_count(manager^)
	if index > MAX_ENTITIES {
		log_warn("Failed to create entity, max entities reached")
        return 99999
	}

    // Get ID from free list or create new
    id: Entity_Id
    if sa.len(manager.free_list) > 0 {
        id = sa.pop_back(&manager.free_list)
        reset_entity_components(manager, index)
    } else {
        id = generate_entity_id(manager^)
    }
    sa.append(&manager.entities, id)
    set_entity_type(manager, index, type)
    manager.entity_to_index[id] = index
    return id
}

// NOTE: remember to update this for every new component!
Component_Data :: struct {
    position: Maybe(Vec2),
    velocity: Maybe(Vec2),
    rotation: Maybe(f32),
    mass: Maybe(f32),
    radius_physics: Maybe(f32),
    damage: Maybe(i32),
    health: Maybe(i32),
    lifespan: Maybe(f32),
    render_type: Maybe(Render_Type),
    radius_render: Maybe(f32),
    color: Maybe(rl.Color),
    scale: Maybe(f32),
    vertices: Maybe(Render_Vertices_Component),
    visual_rotation_rate: Maybe(f32),
    is_visible: Maybe(bool),
    move_timer: Maybe(Timer),
    shot_timer: Maybe(Timer),
    shooter: Maybe(Shooter_Type),
}

// NOTE: remember to update this for every new component!
Component_Request_Data :: struct {
    position: bool,
    velocity: bool,
    rotation: bool,
    mass: bool,
    radius_physics: bool,
    damage: bool,
    health: bool,
    lifespan: bool,
    render_type: bool,
    vertices: bool,
    radius_render: bool,
    color: bool,
    visual_rotation_rate: bool,
    is_visible: bool,
    scale: bool,
    move_timer: bool,
    shot_timer: bool,
    shooter: bool,
}

// NOTE: remember to update this for every new component!
get_component_data :: proc(manager: ^Entity_Manager, id: Entity_Id, request: Component_Request_Data) -> (Component_Data, bool) {
    index, ok := manager.entity_to_index[id]

    if !ok do return {}, false

    data: Component_Data
    // case request.type == true:
    //     data.type = get_entity_type(manager, index)
    if request.position {
        data.position = get_position(manager, index)
    }
    if request.velocity {
        data.velocity = get_velocity(manager, index)
    }
    if request.rotation {
        data.rotation = get_rotation(manager, index)
    }
    if request.mass {
        data.mass = get_mass(manager, index)
    }
    if request.radius_physics {
        data.radius_physics = get_radius_physics(manager, index)
    }
    if request.damage {
        data.damage = get_damage(manager, index)
    }
    if request.health {
        data.health = get_health(manager, index)
    }
    if request.lifespan {
        data.lifespan = get_lifespan(manager, index)
    }
    if request.render_type {
        data.render_type = get_render_type(manager, index)
    }
    if request.radius_render {
        data.radius_render = get_radius_render(manager, index)
    }
    if request.color {
        data.color = get_color(manager, index)
    }
    if request.scale {
        data.scale = get_scale(manager, index)
    }
    if request.visual_rotation_rate {
        data.visual_rotation_rate = get_visual_rotation_rate(manager, index)
    }
    if request.is_visible {
        data.is_visible = get_is_visible(manager, index)
    }
    if request.move_timer {
        data.move_timer = get_move_timer(manager, index)
    }
    if request.shot_timer {
        data.shot_timer = get_shot_timer(manager, index)
    }
    if request.shooter {
        data.shooter = get_shooter(manager, index)
    }
    return data, true
}

// NOTE: remember to update this for every new component!
set_component_data :: proc(manager: ^Entity_Manager, id: Entity_Id, data: Component_Data) -> bool {
    idx, ok_idx := manager.entity_to_index[id]

    if !ok_idx do return false

    // set_entity_type(manager, idx, data.type)
    if val, ok := data.position.?; ok {
        set_position(manager, idx, val)
    }
    if val, ok := data.velocity.?; ok {
        set_velocity(manager, idx, val)
    }
    if val, ok := data.radius_physics.?; ok {
        set_radius_physics(manager, idx, val)
    }
    if val, ok := data.rotation.?; ok {
        set_rotation(manager, idx, val)
    }
    if val, ok := data.mass.?; ok {
        set_mass(manager, idx, val)
    }
    if val, ok := data.lifespan.?; ok {
        set_lifespan(manager, idx, val)
    }
    if val, ok := data.damage.?; ok {
        set_damage(manager, idx, val)
    }
    if val, ok := data.health.?; ok {
        set_health(manager, idx, val)
    }
    if val, ok := data.render_type.?; ok {
        set_render_type(manager, idx, val)
    }
    if val, ok := data.vertices.?; ok {
        set_vertices(manager, idx, val)
    }
    if val, ok := data.radius_render.?; ok {
        set_radius_render(manager, idx, val)
    }
    if val, ok := data.color.?; ok {
        set_color(manager, idx, val)
    }
    if val, ok := data.visual_rotation_rate.?; ok {
        set_visual_rotation_rate(manager, idx, val)
    }
    if val, ok := data.is_visible.?; ok {
        set_is_visible(manager, idx, val)
    } else {
        set_is_visible(manager, idx, true)
    }
    if val, ok := data.scale.?; ok {
        set_scale(manager, idx, val)
    } else {
        set_scale(manager, idx, 1)
    }
    if val, ok := data.move_timer.?; ok {
        set_move_timer(manager, idx, val)
    } else {
        set_move_timer(manager, idx, Timer{})
    }
    if val, ok := data.shot_timer.?; ok {
        set_shot_timer(manager, idx, val)
    } else {
        set_shot_timer(manager, idx, Timer{})
    }
    if val, ok := data.shooter.?; ok {
        set_shooter(manager, idx, val)
    } else {
        set_shooter(manager, idx, .None)
    }
    return true
}

// NOTE: remember to update this for every new component!
_pop_back_entity :: proc(manager: ^Entity_Manager) -> (Entity_Type, Component_Data, Entity_Id, int) {
    last_index := get_last_entity_index(manager^)
    type := get_entity_type(manager, last_index)
    last_id := sa.pop_back(&manager.entities)
    data := Component_Data{
        position = manager.positions[last_index],
        velocity = manager.velocities[last_index],
        rotation = manager.rotations[last_index],
        mass = manager.masses[last_index],
        radius_physics = manager.radii_physics[last_index],
        damage = manager.damages[last_index],
        health = manager.healths[last_index],
        lifespan = manager.lifespans[last_index],
        radius_render = manager.radii_render[last_index],
        color = manager.colors[last_index],
        scale = manager.scales[last_index],
        vertices = manager.vertices[last_index],
        visual_rotation_rate = manager.visual_rotation_rates[last_index],
        is_visible = manager.is_visibles[last_index],
        render_type = manager.rendering.types_render[last_index],
        move_timer = manager.move_timers[last_index],
        shot_timer = manager.shot_timers[last_index],
        shooter = manager.shooters[last_index],
    }
    return type, data, last_id, last_index
}

destroy_entity :: proc(manager: ^Entity_Manager, id_to_destroy: Entity_Id) {
    index_to_swap, ok := manager.entity_to_index[id_to_destroy]
    if !ok {
        log_warn("Failed to destroy entity, missing index from entity_to_index")
         return
    }
    // Get the last active entity. active_count--
    type, swap_data, last_id, last_index_before_pop := _pop_back_entity(manager)

    // Swap components only if entity_destroyed isn't last entity
    if index_to_swap != last_index_before_pop {
        set_entity_type(manager, index_to_swap, type)
        set_component_data(manager, id_to_destroy, swap_data)
    }
    sa.set(&manager.entities, index_to_swap, last_id)
    manager.entity_to_index[last_id] = index_to_swap

    sa.append(&manager.free_list, id_to_destroy)
    delete_key(&manager.entity_to_index, id_to_destroy)
}

update_ship :: proc(manager: ^Entity_Manager, index: int) {
    dt := rl.GetFrameTime()
    switch ship_state^ {
    case .Death:
        tick_timer(&g_mem.death_timer, dt)
        if is_timer_done(g_mem.death_timer) {
            if g_mem.lives <= 0 {
                set_game_over()
            } else {
                ship_state^ = .Spawning
                set_position(g_mem.manager, get_player_index(), Vec2{0,0})
                set_rotation(manager, index, math.to_radians(f32(-90)))
            }
            restart_timer(&g_mem.death_timer)
        }
    case .Teleporting:
        tick_timer(&g_mem.teleport_timer, dt)
        if is_timer_done(g_mem.teleport_timer) {
            rgn_pos_x := rand.float32_range(-0.4, 0.4) * f32(play_span_x())
            rgn_pos_y := rand.float32_range(-0.4, 0.4) * f32(play_span_y())
            new_pos := Vec2{rgn_pos_x, rgn_pos_y}
            set_position(manager, index, new_pos)
            ship_state^ = .Normal
            restart_timer(&g_mem.teleport_timer)
        }
    case .Spawning, .Normal:
        if ship_state^ == .Spawning {
            tick_timer(&g_mem.spawn_timer, dt)
            if is_timer_done(g_mem.spawn_timer) {
                ship_state^ = .Normal
                restart_timer(&g_mem.spawn_timer)
            }
        }

        // Gestures
        last_gesture = current_gesture
        current_gesture = rl.GetGestureDetected()
        touch_pos = rl.GetTouchPosition(0)
        valid_touch := rl.CheckCollisionPointRec(touch_pos, touch_area)

        is_gesture_tap: bool
        is_gesture_hold: bool
        is_gesture_hold_right: bool
        is_gesture_hold_left: bool

        if valid_touch {
            switch {
            case .TAP in current_gesture:
                is_gesture_tap = true
            
            case .HOLD in current_gesture, .DRAG in current_gesture:
                is_gesture_hold = true
                if touch_pos.x < (f32(rl.GetScreenWidth()) / 2) && touch_pos.y > (f32(rl.GetScreenHeight()) / 2) {
                    is_gesture_hold_left = true
                } else if touch_pos.x > (f32(rl.GetScreenWidth()) / 2) && touch_pos.y > (f32(rl.GetScreenHeight()) / 2) {
                    is_gesture_hold_right = true
                }
            }
        }



        if rl.IsKeyPressed(.LEFT_SHIFT) || rl.IsKeyPressed(.RIGHT_SHIFT)  {
            ship_state^ = .Teleporting
            set_velocity(manager, index, {})
        }

        is_thrusting := rl.IsKeyDown(.UP) || rl.IsKeyDown(.W) || is_gesture_hold
        is_thrusting_up := rl.IsKeyReleased(.UP) || rl.IsKeyReleased(.W) || !is_gesture_hold
        if is_thrusting {
            tick_timer(&g_mem.thrust_draw_timer, dt)
            if is_timer_done(g_mem.thrust_draw_timer) {
                restart_timer(&g_mem.thrust_draw_timer)
                g_mem.is_thrust_drawing = !g_mem.is_thrust_drawing
            }
        }
        if is_thrusting_up {
            restart_timer(&g_mem.thrust_draw_timer)
            g_mem.is_thrust_drawing = false
        }
        if is_thrusting && !rl.IsSoundPlaying(sounds[.Thrust]){
                rl.PlaySound(sounds[.Thrust])
        }

        d_rot: f32
        if rl.IsKeyDown(.LEFT) || rl.IsKeyDown(.A) || is_gesture_hold_left {
            d_rot = -SHIP_ROTATION_MAGNITUDE
        }
        if rl.IsKeyDown(.RIGHT) || rl.IsKeyDown(.D) || is_gesture_hold_right {
            d_rot = SHIP_ROTATION_MAGNITUDE
        }

        if rl.IsKeyPressed(.SPACE) || is_gesture_tap {
            if g_mem.ship_active_bullets < SHIP_BULLET_COUNT_LIMIT {
                spawn_bullet_from_ship(manager)
                rl.PlaySound(sounds[.Fire])
                if ship_state^ == .Spawning {
                    ship_state^ = .Normal
                }
            }
        }

        rot := get_rotation(manager, index)
        new_rot := rot
        new_rot += d_rot * dt
        set_rotation(manager, index, new_rot)

        vel := get_velocity(manager, index)
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

        set_velocity(manager, index, new_vel)
    }
}

Spawn_Asteroid_Data :: struct {
    type: Entity_Type,
    pos: Vec2,
    vel: Vec2,
}

update_entities :: proc(manager: ^Entity_Manager, dt: f32) {
    entities_to_destroy_behavioral: [dynamic]int
    defer delete(entities_to_destroy_behavioral)

    n_active_entities := get_active_entity_count(manager^)
	for index in 0..<n_active_entities {

        // Entity Autonomous Behavior
        entity_type := get_entity_type(manager, index)
        switch entity_type {
		case .Ship:
            update_ship(manager, index)
		case .Asteroid_Small, .Asteroid_Medium, .Asteroid_Large:
            rot := get_rotation(manager, index)
            visual_rotation_rate := get_visual_rotation_rate(manager, index)
            set_rotation(manager, index, rot + visual_rotation_rate)
		case .Bullet:
        case .Ufo_Big, .Ufo_Small:
            if !rl.IsSoundPlaying(sounds[.Ufo_Alarm]) {
                rl.PlaySound(sounds[.Ufo_Alarm])
            }
            vel := get_velocity(manager, index)
            move_timer := get_move_timer(manager, index)
            process_ufo_move(manager, index, dt, move_timer, vel, entity_type)

            shot_timer := get_shot_timer(manager, index)
            pos := get_position(manager, index)
            process_ufo_shot(manager, index, dt, shot_timer, entity_type, pos)

        case .None:
		}

        pos := get_position(manager, index)
        vel := get_velocity(manager, index)
        new_pos := pos + vel * dt
        set_position(manager, index, new_pos)

        if (entity_type == .Ufo_Small || entity_type == .Ufo_Big) && is_out_of_bounds_x(new_pos) {
            append(&entities_to_destroy_behavioral, index)
        } 

        // Wraparound
        if new_pos.x <= f32(play_edge_left()) {
            set_position(manager, index, {f32(play_edge_right() - 1), new_pos.y})
        } else if new_pos.x >= f32(play_edge_right()) {
            set_position(manager, index, {f32(play_edge_left() + 1), new_pos.y})
        }
        if new_pos.y <= f32(play_edge_top()) {
            set_position(manager, index, {new_pos.x, f32(play_edge_bottom() - 1)})
        } else if new_pos.y >= f32(play_edge_bottom()) {
            set_position(manager, index, {new_pos.x, f32(play_edge_top() + 1)})
        }
    }
    for index_to_destroy in entities_to_destroy_behavioral {
        id := sa.get(manager.entities, index_to_destroy)
        shooter := get_shooter(manager, index_to_destroy)
        if shooter == .Ship {
            g_mem.ship_active_bullets -= 1
        }
        destroy_entity(manager, id)
    }
}

handle_collisions :: proc(manager: ^Entity_Manager) {
    n_active_entities := get_active_entity_count(manager^)

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

            pos_a := get_position(manager, index_a)
            pos_b := get_position(manager, index_b)
            radius_a := get_radius_physics(manager, index_a)
            radius_b := get_radius_physics(manager, index_b)

            if !rl.CheckCollisionCircles(pos_a, radius_a, pos_b, radius_b) {
                continue
            }

            // check is pair of entities specified, return as such
            type_a := get_entity_type(manager, index_a)
            type_b := get_entity_type(manager, index_b)

            is_some_ship := type_a == .Ship || type_b == .Ship
            is_some_bullet := type_a == .Bullet || type_b == .Bullet

            // Ship collisions
            if is_some_ship && g_mem.ship_state == .Normal {
                is_type_a_ship := type_a == .Ship
                other_index := is_type_a_ship ? index_b : index_a
                other_type := is_type_a_ship ? type_b : type_a

                switch other_type {
                case .Asteroid_Large, .Asteroid_Medium, .Asteroid_Small:
                    aster_position := get_position(manager, other_index)
                    kill_asteroid(manager, &asteroids_to_spawn, &entities_to_destroy, other_type, other_index, .Ship,  aster_position)
                    kill_ship()
                case .Ufo_Big, .Ufo_Small:
                    ufo_position := get_position(manager, other_index)
                    kill_ufo(manager, &entities_to_destroy, other_type, other_index, ufo_position, .Ship)
                    kill_ship()
                case .Bullet:
                    shooter := get_shooter(manager, other_index)
                    if shooter == .Ship {
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
                aster_index := is_type_a_bullet ? index_b : index_a
                aster_type := is_type_a_bullet ? type_b : type_a

                shooter := get_shooter(manager, bullet_index)
                append(&entities_to_destroy, bullet_index)

                aster_position := get_position(manager, aster_index)
                kill_asteroid(manager, &asteroids_to_spawn, &entities_to_destroy, aster_type, aster_index, shooter,  aster_position)
                continue
            }

            is_some_ufo := type_a == .Ufo_Small || type_b == .Ufo_Small || type_a == .Ufo_Big || type_b == .Ufo_Big

            // Collide bullet and ufo
            if is_some_bullet && is_some_ufo {
                is_type_a_bullet := type_a == .Bullet
                bullet_index := is_type_a_bullet ? index_a : index_b
                ufo_index := is_type_a_bullet ? index_b : index_a
                ufo_type := is_type_a_bullet ? type_b : type_a
                ufo_position := get_position(manager, ufo_index)

                shooter := get_shooter(manager, bullet_index)
                if shooter == .Ship {
                    append(&entities_to_destroy, bullet_index)
                    kill_ufo(manager, &entities_to_destroy, ufo_type, ufo_index, ufo_position, shooter)
                } 

                continue
            }

            if is_some_ufo && is_some_asteroid {
                is_type_a_ufo := type_a == .Ufo_Small || type_a == .Ufo_Big
                ufo_type := is_type_a_ufo ? type_a : type_b
                ufo_index := is_type_a_ufo ? index_a : index_b
                ufo_position := get_position(manager, ufo_index)
                aster_index := is_type_a_ufo ? index_b : index_a
                aster_type := is_type_a_ufo ? type_b : type_a
                aster_position := get_position(manager, aster_index)
                kill_ufo(manager, &entities_to_destroy, ufo_type, ufo_index, ufo_position, .None)
                kill_asteroid(manager, &asteroids_to_spawn, &entities_to_destroy, aster_type, aster_index, .None,  aster_position)
                continue
            }
        }
    }

    for index in entities_to_destroy {
        id := sa.get(manager.entities, index)
        shooter := get_shooter(manager, index)
        if shooter == .Ship {
            g_mem.ship_active_bullets -= 1
        }
        destroy_entity(manager, id)
    }

    for data in asteroids_to_spawn {
        spawn_asteroid(data.type, data.pos, data.vel, manager)
    }
}

kill_ship :: proc() {
    if !rl.IsSoundPlaying(sounds[.Death]) {
        rl.PlaySound(sounds[.Death])
    }
    g_mem.lives -= 1
    ship_state^ = .Death
    set_velocity(g_mem.manager, get_player_index(), Vec2{0,0})
}

identify_pair_entity_types :: proc(spec_a: Entity_Type, spec_b: Entity_Type, rcvd_a: Entity_Type, rcvd_b: Entity_Type) -> (is_pair: bool, is_ordered: bool) {
    if spec_a == rcvd_a && spec_b == rcvd_b {
        return true, true
    } else if spec_a == rcvd_b && spec_b == rcvd_a {
        return true, false
    }
    return false, false

}


kill_asteroid :: proc (manager: ^Entity_Manager, asteroids_to_spawn: ^[dynamic]Spawn_Asteroid_Data, entities_to_destroy: ^[dynamic]int, type: Entity_Type, aster_index: int, shooter: Shooter_Type, aster_position: Vec2) {
    aster_velocity := get_velocity(manager, aster_index)
    rl.PlaySound(sounds[.Asteroid_Explode])

    #partial switch type {
    case .Asteroid_Small:
        if shooter == .Ship {
            increment_score(100)
        }

    case .Asteroid_Medium:
        if shooter == .Ship {
            increment_score(50)
        }
        vel_a := jiggle_asteroid_velocity(aster_velocity, 1.5)
        vel_b := jiggle_asteroid_velocity(aster_velocity, 1.5)
        vel_c := jiggle_asteroid_velocity(aster_velocity, 1.5)
        small_positions := spawn_positions_destroyed_medium_asteroid(aster_position, aster_velocity)
        append(asteroids_to_spawn, Spawn_Asteroid_Data{ type = .Asteroid_Small, pos = small_positions[0], vel = vel_a})
        append(asteroids_to_spawn, Spawn_Asteroid_Data{ type = .Asteroid_Small, pos = small_positions[1], vel = vel_b})
        append(asteroids_to_spawn, Spawn_Asteroid_Data{ type = .Asteroid_Small, pos = small_positions[2], vel = vel_c})

    case .Asteroid_Large:
        if shooter == .Ship {
            increment_score(20)
        }
        vel_a := jiggle_asteroid_velocity(aster_velocity)
        vel_b := jiggle_asteroid_velocity(aster_velocity)
        med_positions := spawn_positions_destroyed_large_asteroid (aster_position, aster_velocity)
        append(asteroids_to_spawn, Spawn_Asteroid_Data{ type = .Asteroid_Medium, pos = med_positions[0], vel = vel_a})
        append(asteroids_to_spawn, Spawn_Asteroid_Data{ type = .Asteroid_Medium, pos = med_positions[1], vel = vel_b})
    }
    append(entities_to_destroy, aster_index)
}

kill_ufo :: proc (manager: ^Entity_Manager, entities_to_destroy: ^[dynamic]int, ufo_type: Entity_Type, ufo_index: int, ufo_position: Vec2, shooter: Shooter_Type) {
    rl.PlaySound(sounds[.Asteroid_Explode])
    if shooter == .Ship {
        if ufo_type == .Ufo_Big {
            increment_score(200)
        }
        if ufo_type == .Ufo_Small {
            increment_score(500)
        }
    }
    append(entities_to_destroy, ufo_index)
}

get_entity_type :: proc(manager: ^Entity_Manager, idx: int) -> Entity_Type {
    return manager.types[idx]
}

set_entity_type :: proc(manager: ^Entity_Manager, idx: int, type: Entity_Type) {
    manager.types[idx] = type
}

get_position :: proc(manager: ^Entity_Manager, idx: int) -> Vec2 {
    return manager.positions[idx]
}

set_position :: proc(manager: ^Entity_Manager, idx: int, pos: Vec2) {
    manager.positions[idx] = pos
}

get_velocity :: proc(manager: ^Entity_Manager, idx: int) -> Vec2 {
    return manager.velocities[idx]
}

set_velocity :: proc(manager: ^Entity_Manager, idx: int, vel: Vec2) {
    manager.velocities[idx] = vel
}

get_rotation :: proc(manager: ^Entity_Manager, idx: int) -> f32 {
    return manager.rotations[idx]
}

set_rotation :: proc(manager: ^Entity_Manager, idx: int, rot: f32) {
    manager.rotations[idx] = rot
}

get_mass :: proc(manager: ^Entity_Manager, idx: int) -> f32 {
    return manager.masses[idx]
}

set_mass :: proc(manager: ^Entity_Manager, idx: int, mass: f32) {
    manager.masses[idx] = mass
}

get_radius_physics :: proc(manager: ^Entity_Manager, idx: int) -> f32 {
    return manager.radii_physics[idx]
}

set_radius_physics :: proc(manager: ^Entity_Manager, idx: int, radius: f32) {
    manager.radii_physics[idx] = radius
}

get_lifespan :: proc(manager: ^Entity_Manager, idx: int) -> f32 {
    return manager.lifespans[idx]
}

set_lifespan :: proc(manager: ^Entity_Manager, idx: int, radius: f32) {
    manager.lifespans[idx] = radius
}

get_health :: proc(manager: ^Entity_Manager, idx: int) -> i32 {
    return manager.gameplay.healths[idx]
}

set_health :: proc(manager: ^Entity_Manager, idx: int, health: i32) {
    manager.gameplay.healths[idx] =  health
}

get_damage :: proc(manager: ^Entity_Manager, idx: int) -> i32 {
    return manager.gameplay.damages[idx]
}

set_damage :: proc(manager: ^Entity_Manager, idx: int, damage: i32) {
    manager.gameplay.damages[idx] = damage
}

get_render_type :: proc(manager: ^Entity_Manager, idx: int) -> Render_Type {
    return manager.types_render[idx]
}

set_render_type :: proc(manager: ^Entity_Manager, idx: int, render_type: Render_Type) {
    manager.types_render[idx] = render_type
}

get_vertices :: proc(manager: ^Entity_Manager, idx: int) -> Render_Vertices_Component {
    return manager.rendering.vertices[idx]
}

set_vertices :: proc(manager: ^Entity_Manager, idx: int, vertices: Render_Vertices_Component) {
    manager.rendering.vertices[idx] = vertices
}

get_radius_render :: proc(manager: ^Entity_Manager, idx: int) -> f32 {
    return manager.radii_render[idx]
}

set_radius_render :: proc(manager: ^Entity_Manager, idx: int, radius: f32) {
    manager.radii_render[idx] = radius
}

get_color :: proc(manager: ^Entity_Manager, idx: int) -> rl.Color {
    return manager.colors[idx]
}

set_color :: proc(manager: ^Entity_Manager, idx: int, color: rl.Color) {
    manager.colors[idx] = color
}

get_visual_rotation_rate :: proc(manager: ^Entity_Manager, idx: int) -> f32 {
    return manager.visual_rotation_rates[idx]
}

set_visual_rotation_rate :: proc(manager: ^Entity_Manager, idx: int, visual_rotation_rate: f32) {
    manager.visual_rotation_rates[idx] = visual_rotation_rate
}

get_is_visible :: proc(manager: ^Entity_Manager, idx: int) -> bool {
    return manager.is_visibles[idx]
}

set_is_visible :: proc(manager: ^Entity_Manager, idx: int, is_visibile: bool) {
    manager.is_visibles[idx] = is_visibile
}

get_scale :: proc(manager: ^Entity_Manager, idx: int) -> f32 {
    return manager.scales[idx]
}

set_scale :: proc(manager: ^Entity_Manager, idx: int, scale: f32) {
    manager.scales[idx] = scale
}

get_move_timer :: proc(manager: ^Entity_Manager, idx: int) -> Timer {
    return manager.move_timers[idx]
}

set_move_timer :: proc(manager: ^Entity_Manager, idx: int, move_timer: Timer) {
    manager.move_timers[idx] = move_timer
}

get_shot_timer :: proc(manager: ^Entity_Manager, idx: int) -> Timer {
    return manager.shot_timers[idx]
}

set_shot_timer :: proc(manager: ^Entity_Manager, idx: int, shot_timer: Timer) {
    manager.shot_timers[idx] = shot_timer
}

get_shooter :: proc(manager: ^Entity_Manager, idx: int) -> Shooter_Type {
    return manager.shooters[idx]
}

set_shooter :: proc(manager: ^Entity_Manager, idx: int, shooter: Shooter_Type) {
    manager.shooters[idx] = shooter
}

draw_asteroid :: proc(pos: Vec2, rot: f32, radius: f32, color: rl.Color) {
    rl.DrawPolyLines(pos, N_ASTEROID_SIDES, radius, rot,  color)
}

get_score :: proc() -> i32 {
    return g_mem.score
}

draw_ui :: proc() {
    if g_mem.game_state == .Intro {
        rl.DrawText(
            fmt.ctprint("Thruster = W/Up\n\nRotate = A,D/Left,Right arrows\n\nFire = Space\n\nTeleport = Shift"),
            WINDOW_W * 3 / 8, WINDOW_H * 3 / 5, 30, rl.RAYWHITE,
        )
    }
    rl.DrawText(
        fmt.ctprintf(
            "%v",
            get_score(),
        ),
        75, 30, 42, rl.RAYWHITE,
    )
    for i in 0..<g_mem.lives {
        draw_ship({90 + f32(i) * (SHIP_R * 1.7), 110}, math.to_radians(f32(-90)), 0.9)
    }
    if game_state^ == .Game_Over {
        rl.DrawText(
            fmt.ctprint("GAME OVER\n\nHit Space to play again"),
            WINDOW_W * 3 / 8, WINDOW_H / 2, 40, rl.RAYWHITE,
        )
    }
}

draw_debug_ui :: proc() {
    vel := get_velocity(g_mem.manager, 0)
    speed := linalg.length(vel)
    if DEBUG {
        rl.DrawText(
            fmt.ctprintf(
                "fps: %v\nwin: %vx%v\nlogical: %vx%v\ndt: %v\ndt_running: %v\npos: %v\nvel: %v\nspeed: %v\nhp: %v\nactive_entities: %v\nentities: %v\nfree_list: %v\ngame_state: %v\nship_state: %v\nship_active_bulet: %v",
                rl.GetFPS(),
                rl.GetScreenWidth(),
                rl.GetScreenHeight(),
                LOGICAL_H,
                LOGICAL_W,
                rl.GetFrameTime(),
                rl.GetTime(),
                get_position(g_mem.manager, 0),
                vel,
                speed,
                get_health(g_mem.manager, 0),
                get_active_entity_count(g_mem.manager^),
                sa.slice(&g_mem.entities)[:get_active_entity_count(g_mem.manager^)],
                sa.slice(&g_mem.free_list)[:sa.len(g_mem.free_list)],
                game_state^,
                ship_state^,
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
	if ok {
		return index
	}
	log_warn("Player entity id not in entity_to_index map")
	return -1
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

log_warn :: proc(msg: Maybe(string), loc := #caller_location) {
	fmt.printfln("[%v]WARN: %v", loc, msg.? or_else "")
}

spawn_ship :: proc(pos: Vec2, rot: f32, manager: ^Entity_Manager) -> Entity_Id {
    id := create_entity(manager, .Ship)
    set_component_data(manager, id, Component_Data{
        position = pos,
        rotation = rot,
        velocity = Vec2{0, 0},
        radius_physics = SHIP_R,
        render_type = Render_Type.Ship,
        color = rl.RAYWHITE,
        radius_render = SHIP_R,
        damage = 1,
        health = 3,
        is_visible = true,
    })
    return id
}

spawn_asteroid :: proc(entity_type: Entity_Type, pos: Vec2, vel: Vec2, manager: ^Entity_Manager) {
    id := create_entity(manager, entity_type)
    visual_rotation_rate := rand.float32_range(-2, 2)
    radius: f32
    health: i32
    #partial switch entity_type {
    case .Asteroid_Small:
        radius = SMALL_ASTEROID_RADIUS
        health = 1
    case .Asteroid_Medium:
        radius = SMALL_ASTEROID_RADIUS * 2
        health = 1
    case .Asteroid_Large:
        radius = SMALL_ASTEROID_RADIUS * 4
        health = 1
    }
    data_in := Component_Data{
        position = pos,
        velocity = vel,
        radius_physics = radius,
        render_type = Render_Type.Asteroid,
        color = rl.RAYWHITE,
        radius_render = radius,
        visual_rotation_rate = visual_rotation_rate,
        health = health,
        is_visible = true,
    }
    set_component_data(manager, id, data_in)
}

spawn_bullet_from_ship :: proc(manager: ^Entity_Manager) {
    ship_data, ship_ok := get_component_data(manager, get_player_id(), Component_Request_Data{
        rotation = true,
        position = true,
    })
    if !ship_ok {
        log_warn("Failed to spawn bullet because ship data nil")
        return
    }

    ship_rotation, ok_rotation := ship_data.rotation.?
    if !ok_rotation {
        log_warn("Failed to spawn bullet because ship rotation nil")
        return
    }
    rotation_vector := angle_radians_to_vec(ship_rotation)

    ship_position, ok_position := ship_data.position.?
    if !ok_position {
        log_warn("Failed to spawn bullet because ship position nil")
        return
    }

    pos := ship_position + rotation_vector * SHIP_R
    velocity := rotation_vector * BULLET_SPEED

    g_mem.ship_active_bullets += 1
    spawn_bullet(manager, pos, velocity, .Ship)
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
    case .Harm:
        file = "damage-ship.wav"
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
    sa.resize(&entity_m.entities, 0)
    sa.resize(&entity_m.free_list, 0)
    entity_m.types = {}
    clear(&entity_m.entity_to_index)
    entity_m.physics^ = {}
    entity_m.rendering^ = {}
    entity_m.gameplay^ = {}

	player_id := spawn_ship({0,0}, math.to_radians(f32(-90)), g_mem.manager)
    g_mem.player_id = player_id
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

process_ufo_move :: proc(entitym: ^Entity_Manager, index: int, dt: f32, move_timer: Timer, vel: Vec2, type: Entity_Type) {
    move_timer := move_timer
    tick_timer(&move_timer, dt)
    if is_timer_done(move_timer) {
        chance_to_move : f32 = type == .Ufo_Big ? BIG_UFO_CHANCE_TO_MOVE : SMALL_UFO_CHANCE_TO_MOVE
        rgn := rand.float32()
        if rgn < chance_to_move {
            speed: f32
            if type == .Ufo_Big {
                speed = BIG_UFO_SPEED
            } else if type == .Ufo_Small {
                speed = SMALL_UFO_SPEED
            }
            // bias direction to level. direction based on ratio, avoid rolling again
            // 75% level, 12.5 up/down
            // level
            if rgn < chance_to_move * 0.75 {
                new_vel := vel.x >= 0 ? Vec2{speed, 0} : Vec2{-speed, 0 }
                set_velocity(entitym, index, new_vel)

            // up diag
            } else if rgn < chance_to_move * 0.875 {
                dir := vel.x >= 0 ? Vec2{1, -1} : Vec2{-1, -1}
                new_vel :=  dir * speed
                set_velocity(entitym, index, new_vel)

            // down diag
            } else if rgn < chance_to_move {
                dir := vel.x >= 0 ? Vec2{1, 1} : Vec2{-1, 1}
                new_vel :=  dir * speed
                set_velocity(entitym, index, new_vel)
            }
        }
        restart_timer(&move_timer)
    }
    set_move_timer(entitym, index, move_timer)
}

process_ufo_shot :: proc(entitym: ^Entity_Manager, index: int, dt: f32, shot_timer: Timer, type: Entity_Type, ufo_pos: Vec2) {
    shot_timer := shot_timer
    tick_timer(&shot_timer, dt)
    if is_timer_done(shot_timer) {
        chance_to_shoot : f32 = type == .Ufo_Big ? BIG_UFO_CHANCE_TO_SHOOT : SMALL_UFO_CHANCE_TO_SHOOT
        rgn := rand.float32()
        if rgn < chance_to_shoot {

            // Shot direction
            player_pos := get_position(entitym, get_player_index())
            shot_dir: Vec2
            if type == .Ufo_Big {
                rgn_dir := rand.float32()
                angle_radians := 2 * math.PI * rgn_dir
                shot_dir = {math.cos(angle_radians), math.sin(angle_radians)}
            } else if type == .Ufo_Small {
                d_pos := player_pos - ufo_pos
                shot_dir = linalg.normalize0(d_pos)
            }

            spawn_bullet(entitym, ufo_pos, shot_dir * BULLET_SPEED, .Ufo)
            rl.PlaySound(sounds[.Fire])
        }
        restart_timer(&shot_timer)
    }
    set_shot_timer(entitym, index, shot_timer)
}

spawn_bullet :: proc(manager: ^Entity_Manager, pos: Vec2, vel: Vec2, shooter: Shooter_Type) {
    id := create_entity(manager, .Bullet)
    data_in := Component_Data{
        position = pos,
        velocity = vel,
        damage = 1,
        is_visible = true,
        color = rl.RAYWHITE,
        render_type = Render_Type.Bullet,
        lifespan = BULLET_LIFESPAN,
        shooter = shooter,
        radius_physics = BULLET_PHYSICS_RADIUS,
    }
    set_component_data(manager, id, data_in)
}

reset_entity_components :: proc(manager: ^Entity_Manager, index: int) {
    // Reset all component data to default values
    manager.positions[index] = Vec2{0, 0}
    manager.velocities[index] = Vec2{0, 0}
    manager.rotations[index] = 0
    manager.masses[index] = 0
    manager.radii_physics[index] = 0
    manager.damages[index] = 0
    manager.healths[index] = 0
    manager.lifespans[index] = 0
    manager.types_render[index] = Render_Type.None // Or some sensible default
    manager.radii_render[index] = 0
    manager.colors[index] = rl.RAYWHITE
    manager.scales[index] = 1
    manager.vertices[index] = {}
    manager.visual_rotation_rates[index] = 0
    manager.is_visibles[index] = false
    manager.move_timers[index] = Timer{}
    manager.shot_timers[index] = Timer{}
    manager.shooters[index] = .None
}
