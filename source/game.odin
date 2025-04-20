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

MAX_ENTITIES :: 64
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
    using components: ^Components,
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

Components:: struct {
	positions: [MAX_ENTITIES]Vec2,
	velocities: [MAX_ENTITIES]Vec2,
	rotations: [MAX_ENTITIES]f32,
	radii_physics: [MAX_ENTITIES]f32,
    lifespans: [MAX_ENTITIES]f32,
    shot_timers: [MAX_ENTITIES]Timer,
    move_timers: [MAX_ENTITIES]Timer,
    shooters: [MAX_ENTITIES]Shooter_Type,
	visual_rotation_rates: [MAX_ENTITIES]f32, // asteroid visual rotation
}

Shooter_Type :: enum {
    None,
    Ship,
    Ufo,
}


is_gesture_tap: bool
is_gesture_hold: bool
is_gesture_hold_right: bool
is_gesture_hold_left: bool

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

    is_gesture_hold = false
    is_gesture_hold_left = false
    is_gesture_hold_right = false
    is_gesture_tap = false

    // Gestures
    last_gesture = current_gesture
    current_gesture = rl.GetGestureDetected()
    touch_pos = rl.GetTouchPosition(0)
    valid_touch := rl.CheckCollisionPointRec(touch_pos, touch_area)

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

    // lifespans
    bullets_with_expired_lifespans: [dynamic]int
    defer delete(bullets_with_expired_lifespans)
    for index in 0..<get_active_entity_count() {
        type := get_entity_type(index)
        if type == .Bullet {
            data, _ := get_component_data(get_entity_id(index))
            lifespan := data.lifespan
            new_lifespan := lifespan - dt
            if new_lifespan <= 0 {
                append(&bullets_with_expired_lifespans, index)
            } else {
                set_lifespan(index, new_lifespan)
            }
        }
    }
    for index in bullets_with_expired_lifespans {
        id := sa.get(g_mem.manager.entities, index)
        shooter := get_shooter(index)
        if shooter == .Ship {
            g_mem.ship_active_bullets -= 1
        }
        destroy_entity(id)
    }

    if get_score() > (get_extra_life_count() + 1) * 10000 {
        increment_extra_life_count()
    }

    // The pause between levels, then spawn the level
    count := get_asteroid_count()
    if count == 0 && g_mem.game_state == .Play {
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

    // Update beat levels
    if process_timer(&g_mem.beat_level_timer) {
        g_mem.beat_level = clamp(g_mem.beat_level + 1, 1, 4)
        update_beat_sound_timer_with_level(g_mem.beat_level)
    }

    // Play beat sound IAW beat level
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

spawner_ufo :: proc(beat_level: i32, dt: f32) {
    if !process_timer(&g_mem.ufo_timer) {
        return
    }
    restart_timer(&g_mem.ufo_timer)

    base_chance_big : f32 = BASE_CHANCE_SPAWN_BIG
    big_spawn_factor := base_chance_big * (1 + f32(beat_level) * 0.07)

    // 1/5 chance to spawn small at beat_level == 1
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
    data_in := Component_Data{
        position = pos,
        velocity = is_moving_right ? Vec2{speed,0} : Vec2{-speed,0},
        radius_physics = radius * 0.8,
        move_timer = move_timer,
        shot_timer = shot_timer,
    }
    set_component_data(id, data_in)

}

get_asteroid_count :: proc() -> i32 {
    count : i32 = 0
    for i in 0..<get_active_entity_count() {
        if g_mem.manager.types[i] == .Asteroid_Large || g_mem.manager.types[i] == .Asteroid_Medium || g_mem.manager.types[i] == .Asteroid_Small {
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
	manager.components = new(Components)

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

	player_id := spawn_ship({0,0}, math.to_radians(f32(-90)))
    g_mem.player_id = player_id

    // spawn_asteroid(.Asteroid_Small, {140, 200}, {-20, -100})

    // spawn_asteroid(.Asteroid_Small, {-50, 100}, {0, -100})
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

draw_entities :: proc() {
    dt := rl.GetFrameTime()
    for index in 0..<get_active_entity_count() {
        pos := get_position(index)
        rot := get_rotation(index)

        entity_type := get_entity_type(index)
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
            radius := get_radius_physics(index)
            draw_asteroid(pos, rot, radius)
        case .Bullet:
            draw_bullet(pos)
        case .Ufo_Big, .Ufo_Small:
            draw_ufo(pos, entity_type)
            physics_radius := get_radius_physics(index)
            if DEBUG do rl.DrawCircleLinesV(pos, physics_radius, rl.BLUE)
        case .None:
        }
    }
}

draw_ufo :: proc(pos: Vec2, entity_type: Entity_Type) {
    is_ufo_big := entity_type == .Ufo_Big
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
    vertices: [12]Vec2

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
    radius := get_radius_physics(get_player_index())
    if DEBUG do rl.DrawCircleLinesV(pos, radius, rl.BLUE)
}

draw_ship_thruster :: proc(pos: Vec2, rot: f32, scale: f32 = 1) {
    r : f32 = SHIP_R * scale
    b : f32 = r * 0.25 // butt length
    t := b + (r * 0.5) // thrust exhaust length
    nose_angle := math.to_radians(f32(32))
    b_half_y := (b + r) * math.tan(nose_angle/2) + 1 // add 1, pixel connecting butt to side may or may not render depending on s(?) or r
    thrust_vertices: [12]Vec2
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

get_last_entity_index :: proc() -> int {
    return sa.len(g_mem.manager.entities) - 1
}

get_active_entity_count :: proc() -> int {
    return sa.len(g_mem.manager.entities)
}

generate_entity_id :: proc() -> Entity_Id {
    return Entity_Id(get_active_entity_count())
}

create_entity :: proc( type: Entity_Type) -> Entity_Id {
    manager := g_mem.manager
    index := get_active_entity_count()
	if index > MAX_ENTITIES {
		log_warn("Failed to create entity, max entities reached")
        return 99999
	}

    // Get ID from free list or create new
    id: Entity_Id
    if sa.len(manager.free_list) > 0 {
        id = sa.pop_back(&manager.free_list)
        reset_entity_components(index)
    } else {
        id = generate_entity_id()
    }
    sa.append(&manager.entities, id)
    set_entity_type(index, type)
    manager.entity_to_index[id] = index
    return id
}

// NOTE: remember to update this for every new component!
Component_Data :: struct {
    position: Vec2,
    velocity: Vec2,
    rotation: f32,
    radius_physics: f32,
    lifespan: f32,
    visual_rotation_rate: f32,
    move_timer: Timer,
    shot_timer: Timer,
    shooter: Shooter_Type,
}

// NOTE: remember to update this for every new component!
get_component_data :: proc(id: Entity_Id) -> (Component_Data, bool) {
    index, ok := g_mem.manager.entity_to_index[id]

    if !ok do return {}, false

    data: Component_Data
    // case request.type == true:
    //     data.type = get_entity_type(manager, index)
    data.position = g_mem.manager.components.positions[index]
    data.velocity = g_mem.manager.components.velocities[index]
    data.rotation = g_mem.manager.components.rotations[index]
    data.radius_physics = g_mem.manager.components.radii_physics[index]
    data.lifespan = g_mem.manager.components.lifespans[index]
    data.visual_rotation_rate = g_mem.manager.components.visual_rotation_rates[index]
    data.move_timer = g_mem.manager.components.move_timers[index]
    data.shot_timer = g_mem.manager.components.shot_timers[index]
    data.shooter = g_mem.manager.components.shooters[index]
    return data, true
}
get_position :: proc(idx: int) -> Vec2 {
    return g_mem.manager.components.positions[idx]
}
get_velocity :: proc(idx: int) -> Vec2 {
    return g_mem.manager.components.velocities[idx]
}
get_rotation :: proc(idx: int) -> f32 {
    return g_mem.manager.components.rotations[idx]
}
get_lifespan :: proc(idx: int) -> f32 {
    return g_mem.manager.components.lifespans[idx]
}
get_visual_rotation_rate :: proc(idx: int) -> f32 {
    return g_mem.manager.components.visual_rotation_rates[idx]
}
get_move_timer :: proc(idx: int) -> Timer {
    return g_mem.manager.components.move_timers[idx]
}
get_shot_timer :: proc(idx: int) -> Timer {
    return g_mem.manager.components.shot_timers[idx]
}
get_shooter :: proc(idx: int) -> Shooter_Type {
    return g_mem.manager.components.shooters[idx]
}
get_radius_physics :: proc(idx: int) -> f32 {
    return g_mem.manager.components.radii_physics[idx]
}
set_position :: proc(idx: int, val: Vec2) {
    g_mem.manager.components.positions[idx] = val
}
set_velocity :: proc(idx: int, val: Vec2) {
    g_mem.manager.components.velocities[idx] = val
}
set_rotation :: proc(idx: int, val: f32) {
    g_mem.manager.components.rotations[idx] = val
}
set_physics_radius :: proc(idx: int, val: f32) {
    g_mem.manager.components.radii_physics[idx] = val
}
set_lifespan :: proc(idx: int, val: f32) {
    g_mem.manager.components.lifespans[idx] = val
}
set_visual_rotation_rate :: proc(idx: int, val: f32) {
    g_mem.manager.components.visual_rotation_rates[idx] = val
}
set_move_timer :: proc(idx: int, val: Timer) {
    g_mem.manager.components.move_timers[idx] = val
}
set_shot_timer :: proc(idx: int, val: Timer) {
    g_mem.manager.components.shot_timers[idx] = val
}
set_shooter :: proc(idx: int, val: Shooter_Type) {
    g_mem.manager.components.shooters[idx] = val
}

set_component_data :: proc(id: Entity_Id, data: Component_Data) -> bool {
    idx, ok_idx := g_mem.manager.entity_to_index[id]
    if !ok_idx {
        pr("Index not found for entity_id:", id)
         return false
    }
    set_position(idx, data.position)
    set_velocity(idx, data.velocity)
    set_physics_radius(idx, data.radius_physics)
    set_rotation(idx, data.rotation)
    set_lifespan(idx, data.lifespan)
    set_visual_rotation_rate(idx, data.visual_rotation_rate)
    set_move_timer(idx, data.move_timer)
    set_shot_timer(idx, data.shot_timer)
    set_shooter(idx, data.shooter)
    return true
}

_pop_back_entity :: proc() -> (Entity_Type, Component_Data, Entity_Id, int) {
    last_index := get_last_entity_index()
    type := get_entity_type(last_index)
    last_id := sa.pop_back(&g_mem.manager.entities)
    data := Component_Data{
        position = g_mem.manager.positions[last_index],
        velocity = g_mem.manager.velocities[last_index],
        rotation = g_mem.manager.rotations[last_index],
        radius_physics = g_mem.manager.radii_physics[last_index],
        lifespan = g_mem.manager.lifespans[last_index],
        visual_rotation_rate = g_mem.manager.visual_rotation_rates[last_index],
        move_timer = g_mem.manager.move_timers[last_index],
        shot_timer = g_mem.manager.shot_timers[last_index],
        shooter = g_mem.manager.shooters[last_index],
    }
    return type, data, last_id, last_index
}

destroy_entity :: proc(id_to_destroy: Entity_Id) {
    manager := g_mem.manager
    index_to_swap, ok := manager.entity_to_index[id_to_destroy]
    if !ok {
        log_warn("Failed to destroy entity, missing index from entity_to_index")
         return
    }
    // Get the last active entity. active_count--
    type, swap_data, last_id, last_index_before_pop := _pop_back_entity()

    // Swap components only if entity_destroyed isn't last entity
    if index_to_swap != last_index_before_pop {
        set_entity_type(index_to_swap, type)
        set_component_data(id_to_destroy, swap_data)
    }
    sa.set(&manager.entities, index_to_swap, last_id)
    manager.entity_to_index[last_id] = index_to_swap

    sa.append(&manager.free_list, id_to_destroy)
    delete_key(&manager.entity_to_index, id_to_destroy)
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
                set_position(get_player_index(), Vec2{0,0})
                set_rotation(index, math.to_radians(f32(-90)))
            }
        }
    case .Teleporting:
        if process_timer(&g_mem.teleport_timer) {
            rgn_pos_x := rand.float32_range(-0.4, 0.4) * f32(play_span_x())
            rgn_pos_y := rand.float32_range(-0.4, 0.4) * f32(play_span_y())
            new_pos := Vec2{rgn_pos_x, rgn_pos_y}
            set_position(index, new_pos)
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
            set_velocity(index, {})
        }

        is_thrusting := rl.IsKeyDown(.UP) || rl.IsKeyDown(.W) || is_gesture_hold
        // WARN: removed `|| !is_gesture_hold` below, todo later
        is_thrusting_up := rl.IsKeyReleased(.UP) || rl.IsKeyReleased(.W)  || !is_gesture_hold
        if is_thrusting {
            if process_timer(&g_mem.thrust_draw_timer) {
                g_mem.is_thrust_drawing = !g_mem.is_thrust_drawing
            }
        }
        if is_thrusting_up {
            restart_timer(&g_mem.thrust_draw_timer)
            g_mem.is_thrust_drawing = false
        }
        if is_thrusting && !rl.IsSoundPlaying(g_mem.sounds[.Thrust]){
                rl.PlaySound(g_mem.sounds[.Thrust])
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
                spawn_bullet_from_ship()
                rl.PlaySound(g_mem.sounds[.Fire])
                if g_mem.ship_state == .Spawning {
                    g_mem.ship_state = .Normal
                }
            }
        }

        rot := get_rotation(index)
        new_rot := rot
        new_rot += d_rot * dt
        set_rotation(index, new_rot)

        vel := get_velocity(index)
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

        set_velocity(index, new_vel)
    }
}

Spawn_Asteroid_Data :: struct {
    type: Entity_Type,
    pos: Vec2,
    vel: Vec2,
}

update_entities :: proc( dt: f32) {
    entities_to_destroy_behavioral: [dynamic]int
    defer delete(entities_to_destroy_behavioral)

    n_active_entities := get_active_entity_count()
	for index in 0..<n_active_entities {

        // Entity Autonomous Behavior
        entity_type := get_entity_type(index)
        id := get_entity_id(index)
        data, _ := get_component_data(id)
        switch entity_type {
		case .Ship:
            update_ship(index)
		case .Asteroid_Small, .Asteroid_Medium, .Asteroid_Large:
            rot := data.rotation
            visual_rotation_rate := data.visual_rotation_rate
            new_rot := rot + visual_rotation_rate
            set_rotation(index, new_rot)
		case .Bullet:
        case .Ufo_Big, .Ufo_Small:
            if !rl.IsSoundPlaying(g_mem.sounds[.Ufo_Alarm]) {
                rl.PlaySound(g_mem.sounds[.Ufo_Alarm])
            }
            vel := get_velocity(index)
            move_timer := get_move_timer(index)
            process_ufo_move(index, dt, move_timer, vel, entity_type)

            shot_timer := get_shot_timer(index)
            pos := get_position(index)
            process_ufo_shot(index, dt, shot_timer, entity_type, pos)

        case .None:
		}

        pos := get_position(index)
        vel := get_velocity(index)
        new_pos := pos + vel * dt
        set_position(index, new_pos)

        if (entity_type == .Ufo_Small || entity_type == .Ufo_Big) && is_out_of_bounds_x(new_pos) {
            append(&entities_to_destroy_behavioral, index)
        } 

        // Wraparound
        if new_pos.x <= f32(play_edge_left()) {
            set_position(index, {f32(play_edge_right() - 1), new_pos.y})
        } else if new_pos.x >= f32(play_edge_right()) {
            set_position(index, {f32(play_edge_left() + 1), new_pos.y})
        }
        if new_pos.y <= f32(play_edge_top()) {
            set_position(index, {new_pos.x, f32(play_edge_bottom() - 1)})
        } else if new_pos.y >= f32(play_edge_bottom()) {
            set_position(index, {new_pos.x, f32(play_edge_top() + 1)})
        }
    }
    for index_to_destroy in entities_to_destroy_behavioral {
        id := get_entity_id(index_to_destroy)
        shooter := get_shooter(index_to_destroy)
        if shooter == .Ship {
            g_mem.ship_active_bullets -= 1
        }
        destroy_entity(id)
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

            pos_a := get_position(index_a)
            pos_b := get_position(index_b)
            radius_a := get_radius_physics(index_a)
            radius_b := get_radius_physics(index_b)

            if !rl.CheckCollisionCircles(pos_a, radius_a, pos_b, radius_b) {
                continue
            }

            // check is pair of entities specified, return as such
            type_a := get_entity_type(index_a)
            type_b := get_entity_type(index_b)

            is_some_ship := type_a == .Ship || type_b == .Ship
            is_some_bullet := type_a == .Bullet || type_b == .Bullet

            // Ship collisions
            if is_some_ship && g_mem.ship_state == .Normal {
                is_type_a_ship := type_a == .Ship
                other_index := is_type_a_ship ? index_b : index_a
                other_type := is_type_a_ship ? type_b : type_a

                switch other_type {
                case .Asteroid_Large, .Asteroid_Medium, .Asteroid_Small:
                    aster_position := get_position(other_index)
                    kill_asteroid(&asteroids_to_spawn, &entities_to_destroy, other_type, other_index, .Ship,  aster_position)
                    kill_ship()
                case .Ufo_Big, .Ufo_Small:
                    ufo_position := get_position(other_index)
                    kill_ufo(&entities_to_destroy, other_type, other_index, ufo_position, .Ship)
                    kill_ship()
                case .Bullet:
                    shooter := get_shooter(other_index)
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

                shooter := get_shooter(bullet_index)
                append(&entities_to_destroy, bullet_index)

                aster_position := get_position(aster_index)
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
                ufo_position := get_position(ufo_index)

                shooter := get_shooter(bullet_index)
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
                ufo_position := get_position(ufo_index)
                aster_index := is_type_a_ufo ? index_b : index_a
                aster_type := is_type_a_ufo ? type_b : type_a
                aster_position := get_position(aster_index)
                kill_ufo(&entities_to_destroy, ufo_type, ufo_index, ufo_position, .None)
                kill_asteroid(&asteroids_to_spawn, &entities_to_destroy, aster_type, aster_index, .None,  aster_position)
                continue
            }
        }
    }

    for index_to_destroy in entities_to_destroy {
        id := get_entity_id(index_to_destroy)
        shooter := get_shooter(index_to_destroy)
        if shooter == .Ship {
            g_mem.ship_active_bullets -= 1
        }
        destroy_entity(id)
    }

    for data in asteroids_to_spawn {
        spawn_asteroid(data.type, data.pos, data.vel)
    }
}

kill_ship :: proc() {
    if !rl.IsSoundPlaying(g_mem.sounds[.Death]) {
        rl.PlaySound(g_mem.sounds[.Death])
    }
    g_mem.lives -= 1
    g_mem.ship_state = .Death
    set_velocity(get_player_index(), Vec2{0,0})
}

identify_pair_entity_types :: proc(spec_a: Entity_Type, spec_b: Entity_Type, rcvd_a: Entity_Type, rcvd_b: Entity_Type) -> (is_pair: bool, is_ordered: bool) {
    if spec_a == rcvd_a && spec_b == rcvd_b {
        return true, true
    } else if spec_a == rcvd_b && spec_b == rcvd_a {
        return true, false
    }
    return false, false

}


kill_asteroid :: proc (asteroids_to_spawn: ^[dynamic]Spawn_Asteroid_Data, entities_to_destroy: ^[dynamic]int, type: Entity_Type, aster_index: int, shooter: Shooter_Type, aster_position: Vec2) {
    aster_velocity := get_velocity(aster_index)
    rl.PlaySound(g_mem.sounds[.Asteroid_Explode])

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

kill_ufo :: proc (entities_to_destroy: ^[dynamic]int, ufo_type: Entity_Type, ufo_index: int, ufo_position: Vec2, shooter: Shooter_Type) {
    rl.PlaySound(g_mem.sounds[.Asteroid_Explode])
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

get_entity_type :: proc(idx: int) -> Entity_Type {
    return g_mem.manager.types[idx]
}

set_entity_type :: proc(idx: int, type: Entity_Type) {
    g_mem.manager.types[idx] = type
}

draw_asteroid :: proc(pos: Vec2, rot: f32, radius: f32) {
    rl.DrawPolyLines(pos, N_ASTEROID_SIDES, radius, rot, rl.RAYWHITE)
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
        draw_ship({90 + f32(i) * (SHIP_R * 1.7), 110}, math.to_radians(f32(-90)), 0.75)
    }
    if g_mem.game_state == .Game_Over {
        rl.DrawText(
            fmt.ctprint("GAME OVER\n\nHit Space to play again"),
            WINDOW_W * 3 / 8, WINDOW_H / 2, 40, rl.RAYWHITE,
        )
    }
}

draw_debug_ui :: proc() {
    vel := get_velocity(0)
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
                get_position(0),
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
	if ok {
		return index
	}
	log_warn("Player entity id not in entity_to_index map")
	return -1
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

log_warn :: proc(msg: Maybe(string), loc := #caller_location) {
	fmt.printfln("[%v]WARN: %v", loc, msg.? or_else "")
}

spawn_ship :: proc(pos: Vec2, rot: f32) -> Entity_Id {
    id := create_entity(.Ship)
    set_component_data(id, Component_Data{
        position = pos,
        rotation = rot,
        velocity = Vec2{0, 0},
        radius_physics = SHIP_R,
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
        radius = SMALL_ASTEROID_RADIUS * 2
    case .Asteroid_Large:
        radius = SMALL_ASTEROID_RADIUS * 4
    }
    data_in := Component_Data{
        position = pos,
        velocity = vel,
        radius_physics = radius,
        visual_rotation_rate = visual_rotation_rate,
    }
    set_component_data(id, data_in)
}

spawn_bullet_from_ship :: proc() {
    ship_data, ship_ok := get_component_data(get_player_id())
    if !ship_ok {
        log_warn("Failed to spawn bullet because ship data nil")
        return
    }

    ship_rotation := ship_data.rotation
    rotation_vector := angle_radians_to_vec(ship_rotation)

    ship_position := ship_data.position

    pos := ship_position + rotation_vector * SHIP_R
    velocity := rotation_vector * BULLET_SPEED

    g_mem.ship_active_bullets += 1
    spawn_bullet(pos, velocity, .Ship)
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
    sa.resize(&g_mem.manager.entities, 0)
    sa.resize(&g_mem.manager.free_list, 0)
    g_mem.manager.types = {}
    clear(&g_mem.entity_to_index)
    g_mem.manager.components^ = {}

	player_id := spawn_ship({0,0}, math.to_radians(f32(-90)))
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
            // bias direction to level. direction based on ratio, avoid rolling again
            // 75% level, 12.5 up/down
            // level
            if rgn < chance_to_move * 0.75 {
                new_vel := vel.x >= 0 ? Vec2{speed, 0} : Vec2{-speed, 0 }
                set_velocity(index, new_vel)

            // up diag
            } else if rgn < chance_to_move * 0.875 {
                dir := vel.x >= 0 ? Vec2{1, -1} : Vec2{-1, -1}
                new_vel :=  dir * speed
                set_velocity(index, new_vel)

            // down diag
            } else if rgn < chance_to_move {
                dir := vel.x >= 0 ? Vec2{1, 1} : Vec2{-1, 1}
                new_vel :=  dir * speed
                set_velocity(index, new_vel)
            }
        }
    }
    set_move_timer(index, move_timer)
}

process_ufo_shot :: proc(index: int, dt: f32, shot_timer: Timer, type: Entity_Type, ufo_pos: Vec2) {
    shot_timer := shot_timer
    if process_timer(&shot_timer) {
        chance_to_shoot : f32 = type == .Ufo_Big ? BIG_UFO_CHANCE_TO_SHOOT : SMALL_UFO_CHANCE_TO_SHOOT
        rgn := rand.float32()
        if rgn < chance_to_shoot {

            // Shot direction
            player_pos := get_position(get_player_index())
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
    set_shot_timer(index, shot_timer)
}

spawn_bullet :: proc(pos: Vec2, vel: Vec2, shooter: Shooter_Type) {
    id := create_entity(.Bullet)
    data_in := Component_Data{
        position = pos,
        velocity = vel,
        lifespan = BULLET_LIFESPAN,
        shooter = shooter,
        radius_physics = BULLET_PHYSICS_RADIUS,
    }
    set_component_data(id, data_in)
}

reset_entity_components :: proc(index: int) {
    // Reset all component data to default values
    manager := g_mem.manager
    manager.positions[index] = Vec2{0, 0}
    manager.velocities[index] = Vec2{0, 0}
    manager.rotations[index] = 0
    manager.radii_physics[index] = 0
    manager.lifespans[index] = 0
    manager.visual_rotation_rates[index] = 0
    manager.move_timers[index] = Timer{}
    manager.shot_timers[index] = Timer{}
    manager.shooters[index] = .None
}

set_game_over :: proc() {
    g_mem.game_state = .Game_Over
}

eval_game_over :: proc() {
    if rl.IsKeyPressed(.V) && DEBUG {
        set_game_over()
    }

    if g_mem.game_state == .Game_Over {
        if rl.IsKeyPressed(.SPACE) || is_gesture_tap {
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
