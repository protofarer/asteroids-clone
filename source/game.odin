package game

import "core:fmt"
import rl "vendor:raylib"
import sa "core:container/small_array"
import math "core:math"
import linalg "core:math/linalg"
import rand "core:math/rand"

pr :: fmt.println
Vec2 :: rl.Vector2

DEBUG :: true
WINDOW_W :: 1800
WINDOW_H :: 1000
LOGICAL_W :: 1000
LOGICAL_H :: 750

PHYSICS_HZ :: 120
FIXED_DT :: 1 / PHYSICS_HZ

MAX_ENTITIES :: 128
N_ASTEROID_SIDES :: 8
SMALL_ASTEROID_RADIUS :: 15

BIG_UFO_RADIUS :: 25
SMALL_UFO_RADIUS :: 12

SHIP_R :: 22
SHIP_ROTATION_MAGNITUDE :: 5
SHIP_MAX_SPEED :: 350
THRUST_MAGNITUDE :: 6
SPACE_FRICTION_COEFFICIENT :: 0.01 // cause of plasma and charged dust

BULLET_COUNT_LIMIT :: 4
BULLET_SPEED :: 500
BULLET_LIFESPAN_SPEED_RATIO :: 0.0018
BULLET_LIFESPAN :: BULLET_SPEED * BULLET_LIFESPAN_SPEED_RATIO

TIMER_INTERVAL_DEATH :: 1
TIMER_INTERVAL_SPAWN :: 2
TIMER_INTERVAL_BETWEEN_LEVELS :: 1
TIMER_INTERVAL_BEAT :: 15
TIMER_INTERVAL_UFO :: 3
INIT_TIMER_INTERVAL_BEAT_SOUND :: 4

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
}

Game_State :: enum {
    Between_Levels,
    Play,
    Game_Over,
}

Ship_State :: enum {
    Normal,
    Death,
    Spawning,
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
}

Entity_Id :: distinct u32

Entity_Manager :: struct {
	entities: sa.Small_Array(MAX_ENTITIES, Entity_Id), // len used as active_entity_count, order doesn't align with components
	free_list: sa.Small_Array(MAX_ENTITIES, Entity_Id),
	types: [MAX_ENTITIES]Entity_Type, // CSDR moving this under gameplay or other?? the data flow (set/get) is disjointed
	entity_to_index: map[Entity_Id]int,

    // TODO: CSDR moving to a Component_Manager
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
    if rl.IsKeyPressed(.V) {
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
    update_entities(entity_m, dt)

    // The pause between levels, then spawn the level
    count := get_asteroid_count(entity_m^)
    if count == 0 && game_state^ == .Play {
        game_state^ = .Between_Levels
    } else if game_state^ == .Between_Levels {
        tick_timer(&g_mem.between_levels_timer, dt)
        if is_timer_done(g_mem.between_levels_timer) {
            game_state^ = .Play
            restart_timer(&g_mem.between_levels_timer)
            spawn_level(entity_m)
            restart_timer(&g_mem.beat_level_timer)
            g_mem.beat_level = 1
        }
    }

    // Update beat levels
    tick_timer(&g_mem.beat_level_timer, dt)
    if is_timer_done(g_mem.beat_level_timer) {
        g_mem.beat_level = clamp(g_mem.beat_level + 1, 1, 3)
        update_beat_sound_timer_with_level(g_mem.beat_level)
    }

    // Play beat sound IAW beat level
    tick_timer(&g_mem.beat_sound_timer, dt)
    if is_timer_done(g_mem.beat_sound_timer) {
        // TODO:
        // rl.PlaySound(sounds[.Beat])
    }

    // Spawn Ufos
    tick_timer(&g_mem.ufo_timer, dt)
    if is_timer_done(g_mem.ufo_timer) {
        spawner_ufo(g_mem.beat_level)
    }
}

spawner_ufo :: proc(beat_level: i32) {
    // multiply beat_level by some factor and then chance to spawn ufo
    // only spawn every interval
    rgn := rand.float32()
    base_probability :: 0.15
    probability := f32(beat_level) * base_probability
    if rgn < probability {
        // TODO: rand left or right wall, y_pos
        spawn_ufo(.Ufo_Big, { 50, -50 }, true, entity_m)
    }
}

spawn_ufo :: proc(entity_type: Entity_Type, pos: Vec2, is_moving_right: bool, entity_m: ^Entity_Manager) {
    id := create_entity(entity_m, entity_type)
    radius: f32
    #partial switch entity_type {
    case .Ufo_Big:
        radius = BIG_UFO_RADIUS
    case .Ufo_Small:
        radius = SMALL_UFO_RADIUS
    }
    data_in := Component_Data{
        position = pos,
        velocity = is_moving_right ? Vec2{1,0} : Vec2{-1,0},
        radius_physics = radius,
        render_type = Render_Type.Ufo_Big,
        color = rl.RAYWHITE,
        radius_render = radius,
        health = 1,
        is_visible = true,
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
    @(static) level : i32 = 1
    @(static) spawn_offset : f32 = 10
    for _ in 0..<level+3 {
        unit_direction := make_random_direction()
        speed := rand.float32_range(50,120)
        vel := speed * unit_direction

        pos: Vec2

        rgn := rand.float32_range(0, 4)
        pr("rgn:", rgn)
        // top boundary
        if rgn < 1 {
            span_proportion := rgn
            dx := span_proportion * f32(play_span_x())
            x := f32(play_edge_left()) + dx
            y := f32(play_edge_top()) + spawn_offset
            pos = {x,y}

        // right boundary
        } else if rgn < 2 {
            span_proportion := rgn - 1
            dy := span_proportion * f32(play_span_y())
            x := f32(play_edge_right()) - spawn_offset
            y := f32(play_edge_top()) + dy
            pos = {x,y}

        // bot boundary
        } else if rgn < 3 {
            span_proportion := rgn - 2
            dx := span_proportion * f32(play_span_x())
            x := f32(play_edge_left()) + dx
            y := f32(play_edge_bottom()) - spawn_offset
            pos = {x,y}

        // left boundary
        } else if rgn < 4 {
            span_proportion := rgn - 3
            dy := span_proportion * f32(play_span_y())
            x := f32(play_edge_left()) + spawn_offset
            y := f32(play_edge_top()) + dy
            pos = {x,y}
        }
        spawn_asteroid(.Asteroid_Large, pos, vel, entity_m)
    }
    level += 1
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
    rl.DrawRectangleLines(i32(screen_left()), i32(screen_top() + 1), LOGICAL_W, LOGICAL_H, rl.BLUE)
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
	rl.InitWindow(WINDOW_W, WINDOW_H, "Kaivalya")
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
    g_mem.game_state = .Between_Levels
    g_mem.lives = 3
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
            case .Death:
                draw_ship_death(pos)
            case .Spawning:
                draw_ship_spawning(pos, rot, vertices, color, dt, scale)
            }
        case .Asteroid:
            radius := get_radius_physics(manager, index)
            draw_asteroid(pos, rot, radius, get_color(manager, index))
        case .Bullet:
            draw_bullet(pos, color)
        case .Particle:
            rl.DrawCircleV(pos, 1.0, color)
        case .Ufo_Big, .Ufo_Small:
            draw_ufo_big(pos, color)
        }
    }
}

draw_ufo_big :: proc(pos: Vec2, color: rl.Color) {
    rl.DrawCircleV(pos, BIG_UFO_RADIUS, color)
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
    r := SHIP_R * scale
    tail_angle := math.to_radians(f32(39))
    vertices: Render_Vertices_Component
    vertices[0] = scale * Vec2{r, 0}
    vertices[1] =  scale * Vec2{-r*math.cos(tail_angle), -r*math.sin(tail_angle)}
    vertices[2] =  scale * Vec2{-r*0.25, 0} * 0.5
    vertices[3] =  scale * Vec2{-r*math.cos(tail_angle), r*math.sin(tail_angle)}
    for &vertex in vertices {
        vertex = rotate_point(vertex, {0, 0}, rot) + pos
    }
    for i in 0..<3 {
        rl.DrawLineV(vertices[i], vertices[i+1], rl.RAYWHITE)
    }
    rl.DrawLineV(vertices[3], vertices[0], rl.RAYWHITE)
    if DEBUG do rl.DrawPixelV(pos, rl.RAYWHITE)
}

rotate_point :: proc(point: Vec2, center: Vec2, rot: f32 /* rad */) -> Vec2 {
    delta := point - center
    // TODO: work on this, flipped in between sign
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
	// pr_span("IN create_entity")

    index := get_active_entity_count(manager^)
	if index > MAX_ENTITIES {
		log_warn("Failed to create entity, max entities reached")
        return 99999
	}

    // Get ID from free list or create new
    id: Entity_Id
    if sa.len(manager.free_list) > 0 {
        id = sa.pop_back(&manager.free_list)
    } else {
        id = generate_entity_id(manager^)
    }
    sa.append(&manager.entities, id)
    set_entity_type(manager, index, type)
    manager.entity_to_index[id] = index
    return id
}

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
}

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
}

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
    return data, true
}

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
    return true
}

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
            }
            restart_timer(&g_mem.death_timer)
        }
    case .Spawning, .Normal:
        if ship_state^ == .Spawning {
            tick_timer(&g_mem.spawn_timer, dt)
            if is_timer_done(g_mem.spawn_timer) {
                ship_state^ = .Normal
                restart_timer(&g_mem.spawn_timer)
            }
        }
        rot := get_rotation(manager, index)
        pos := get_position(manager, index)
        vel := get_velocity(manager, index)

        d_rot: f32
        is_thrusting := rl.IsKeyDown(.DOWN) || rl.IsKeyDown(.S)
        if is_thrusting && !rl.IsSoundPlaying(sounds[.Thrust]){
                rl.PlaySound(sounds[.Thrust])
        }
        if rl.IsKeyDown(.LEFT) || rl.IsKeyDown(.A) {
            d_rot = -SHIP_ROTATION_MAGNITUDE
        }
        if rl.IsKeyDown(.RIGHT) || rl.IsKeyDown(.D) {
            d_rot = SHIP_ROTATION_MAGNITUDE
        }
        if rl.IsKeyPressed(.SPACE) {
            if ship_state^ == .Spawning {
                ship_state^ = .Normal
            }
            bullet_count: i32
            for entity_type in manager.types[:get_active_entity_count(manager^)] {
                if entity_type == .Bullet {
                    bullet_count += 1
                }
            }
            if bullet_count < 4 {
                spawn_bullet_from_ship(manager)
                rl.PlaySound(sounds[.Fire])
            }
        }

        rot += d_rot * dt
        heading : Vec2 = {math.cos(rot), math.sin(rot)} // aka facing, not ship velocity nor direction of movement of body

        if !is_thrusting {
            vel -= vel * SPACE_FRICTION_COEFFICIENT
        } else {
            vel += THRUST_MAGNITUDE * heading
        }

        if linalg.length(vel) > SHIP_MAX_SPEED {
            dir := linalg.normalize0(vel)
            vel = dir * SHIP_MAX_SPEED
        }
        pos += vel * dt

        set_rotation(manager, index, rot)
        set_position(manager, index, pos)
        set_velocity(manager, index, vel)
    } // switch/case
}

update_entities :: proc(manager: ^Entity_Manager, dt: f32) {
    // pr("entities:",sa.slice(&manager.entities)[:(sa.len(manager.entities))])
    // pr("entity_to_idx:",manager.entity_to_index)
    // pr("free_list:",sa.slice(&manager.free_list)[:(sa.len(manager.free_list))])
    // pr_span("")
    entities_to_destroy: [dynamic]int
    defer delete(entities_to_destroy)
    Spawn_Asteroid_Data :: struct {
        type: Entity_Type,
        pos: Vec2,
        vel: Vec2,
    }
    asteroids_to_spawn: [dynamic]Spawn_Asteroid_Data
    defer delete(asteroids_to_spawn)
	for index in 0..<get_active_entity_count(manager^) {
        entity_type := get_entity_type(manager, index)
        switch entity_type {
		case .Ship:
            update_ship(manager, index)
		case .Asteroid_Small, .Asteroid_Medium, .Asteroid_Large:
            vel := get_velocity(manager, index)
            pos := get_position(manager, index)
            set_position(manager, index, pos + vel * dt)
            rot := get_rotation(manager, index)
            visual_rotation_rate := get_visual_rotation_rate(manager, index)
            set_rotation(manager, index, rot + visual_rotation_rate)
		case .Bullet:
            vel := get_velocity(manager, index)
            pos := get_position(manager, index)
            set_position(manager, index, pos + vel * dt)
        case .Ufo_Big, .Ufo_Small:
            // TODO: change velocity every so often, just use a global Ufo movement timer
            // TODO: every timer interval, there's a chance to move diag up, diag down, or straight
            // TODO: every ufo_fire_timer interval, chance to fire
            // TODO: ufo big fires randomly
            // TODO: ufo small fires at ship pos
        case .None:
		}
        pos := get_position(manager, index)
        if pos.x <= f32(play_edge_left()) {
            set_position(manager, index, {f32(play_edge_right() - 1), pos.y})
        } else if pos.x >= f32(play_edge_right()) {
            set_position(manager, index, {f32(play_edge_left() + 1), pos.y})
        }
        if pos.y <= f32(play_edge_top()) {
            set_position(manager, index, {pos.x, f32(play_edge_bottom() - 1)})
        } else if pos.y >= f32(play_edge_bottom()) {
            set_position(manager, index, {pos.x, f32(play_edge_top() + 1)})
        }

        if ship_state^ != .Normal {
            continue
        }
        // Collsions against ship
        if entity_type == .Asteroid_Small || entity_type == .Asteroid_Medium || entity_type == .Asteroid_Large {
            ship_position := get_position(manager, get_player_index())
            ship_radius := get_radius_physics(manager, get_player_index())
            entity_radius := get_radius_physics(manager, index)
            if rl.CheckCollisionCircles(pos, entity_radius, ship_position, ship_radius) {
                ship_health := get_health(manager, index)

                if ship_health - 1 <= 0 {
                    if !rl.IsSoundPlaying(sounds[.Death]) {
                        rl.PlaySound(sounds[.Death])
                    }
                    g_mem.lives -= 1
                    ship_state^ = .Death
                    set_position(manager, get_player_index(), Vec2{0,0})
                    set_rotation(manager, get_player_index(), math.to_radians(f32(-90)))
                    set_velocity(manager, get_player_index(), Vec2{0,0})
                }

                if !rl.IsSoundPlaying(sounds[.Harm]) {
                    rl.PlaySound(sounds[.Harm])
                }
                set_health(manager,index,ship_health-1)
            }
        }
        // Collisions with bullets
        if entity_type == .Bullet {
            for index_b in 0..<get_active_entity_count(manager^) {
                entity_type_b := get_entity_type(manager, index_b)
                if entity_type_b == .Asteroid_Small || entity_type_b == .Asteroid_Medium || entity_type_b == .Asteroid_Large {
                    aster_index := index_b
                    aster_radius := get_radius_physics(manager, aster_index)
                    aster_position := get_position(manager, aster_index)
                    bullet_radius := get_radius_physics(manager, index)

                    if rl.CheckCollisionCircles(pos, bullet_radius, aster_position, aster_radius) {
                        // Don't re-destroy bullets already slated for destruction
                        is_slated_destruction := false
                        for destroy_index in entities_to_destroy {
                            if index == destroy_index {
                                is_slated_destruction = true
                                break
                            }
                        }
                        if !is_slated_destruction {
                            rl.PlaySound(sounds[.Bullet_Impact])
                            append(&entities_to_destroy, index)
                        }

                        // asteroid resolution
                        health := get_health(manager, aster_index)
                        if health - 1 <= 0 {
                            aster_velocity := get_velocity(manager, aster_index)
                            rl.PlaySound(sounds[.Asteroid_Explode])

                            #partial switch entity_type_b {
                            case .Asteroid_Small:
                                increment_score(20)

                            case .Asteroid_Medium:
                                increment_score(50)
                                vel_a := jiggle_asteroid_velocity(aster_velocity)
                                vel_b := jiggle_asteroid_velocity(aster_velocity)
                                vel_c := jiggle_asteroid_velocity(aster_velocity)
                                small_positions := spawn_positions_destroyed_medium_asteroid(aster_position, aster_velocity)
                                append(&asteroids_to_spawn, Spawn_Asteroid_Data{ type = .Asteroid_Small, pos = small_positions[0], vel = vel_a})
                                append(&asteroids_to_spawn, Spawn_Asteroid_Data{ type = .Asteroid_Small, pos = small_positions[1], vel = vel_b})
                                append(&asteroids_to_spawn, Spawn_Asteroid_Data{ type = .Asteroid_Small, pos = small_positions[2], vel = vel_c})

                            case .Asteroid_Large:
                                increment_score(100)
                                vel_a := jiggle_asteroid_velocity(aster_velocity)
                                vel_b := jiggle_asteroid_velocity(aster_velocity)
                                med_positions := spawn_positions_destroyed_large_asteroid (aster_position, aster_velocity)
                                append(&asteroids_to_spawn, Spawn_Asteroid_Data{ type = .Asteroid_Medium, pos = med_positions[0], vel = vel_a})
                                append(&asteroids_to_spawn, Spawn_Asteroid_Data{ type = .Asteroid_Medium, pos = med_positions[1], vel = vel_b})
                            }
                            if get_score() > (get_extra_life_count() + 1) * 10000 {
                                increment_extra_life_count()
                                ship_health := get_health(manager, index)
                                set_health(manager, index, ship_health + 1)
                            }
                            append(&entities_to_destroy, aster_index)
                        }
                    }
                }
            }
        }

        if entity_type == .Bullet {
            lifespan := get_lifespan(manager, index)
            lifespan -= dt
			if lifespan <= 0 {
                append(&entities_to_destroy, index)
			} else {
                set_lifespan(manager, index, lifespan)
            }
        }
	}
    for index in entities_to_destroy {
        id := sa.get(manager.entities, index)
        destroy_entity(manager, id)
    }
    for data in asteroids_to_spawn {
        spawn_asteroid(data.type, data.pos, data.vel, manager)
    }
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
    // TODO: check this works, ship is appending more vertices
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

draw_asteroid :: proc(pos: Vec2, rot: f32, radius: f32, color: rl.Color) {
    rl.DrawPolyLines(pos, N_ASTEROID_SIDES, radius, rot,  color)
}

get_score :: proc() -> i32 {
    return g_mem.score
}
draw_score:: proc() {
    rl.DrawText(
        fmt.ctprintf(
            "%v",
            get_score(),
        ),
        300, 30, 42, rl.WHITE,
    )
}
draw_lives :: proc() {
    for i in 0..<g_mem.lives {
        draw_ship({315 + f32(i) * (SHIP_R * 1.7), 110}, math.to_radians(f32(-90)), 0.9)
    }
}
draw_game_over :: proc () {
    rl.DrawText(
        fmt.ctprint("GAME OVER\nPress SPACE to play again"),
        WINDOW_W / 2, WINDOW_H / 2, 40, rl.WHITE,
    )
}

draw_ui :: proc() {
    draw_score()
    draw_lives()
    if game_state^ == .Game_Over {
        draw_game_over()
    }
}

draw_debug_ui :: proc() {
    vel := get_velocity(g_mem.manager, 0)
    speed := linalg.length(vel)
    if DEBUG {
        rl.DrawText(
            fmt.ctprintf(
                "fps: %v\nwin: %vx%v\nlogical: %vx%v\ndt_running: %v\npos: %v\nvel: %v\nspeed: %v\nhp: %v\nactive_entities: %v\nentities: %v\nfree_list: %v\ngame_state: %v\nship_state: %v",
                rl.GetFPS(),
                rl.GetScreenWidth(),
                rl.GetScreenHeight(),
                LOGICAL_H,
                LOGICAL_W,
                rl.GetTime(),
                get_position(g_mem.manager, 0),
                vel,
                speed,
                get_health(g_mem.manager, 0),
                get_active_entity_count(g_mem.manager^),
                sa.slice(&g_mem.entities)[:sa.len(g_mem.entities)],
                sa.slice(&g_mem.free_list)[:sa.len(g_mem.free_list)],
                game_state^,
                ship_state^,
            ),
            3, 3, 12, rl.WHITE,
        )
        rl.DrawText(
            fmt.ctprintf(
                "cam.tar: %v\ncam.off: %v\nscreen_left: %v\nscreen_right: %v",
                game_camera().target,
                game_camera().offset,
                screen_left(),
                screen_right(),
            ),
            i32(rl.GetScreenWidth() - 210), 3, 12, rl.WHITE,
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
    id := create_entity(manager, .Bullet)
    ship_data, ship_ok := get_component_data(manager, get_player_id(), Component_Request_Data{
        rotation = true,
        position = true,
    })
    if !ship_ok {
        log_warn("Failed to spawn bullet because ship data nil")
        destroy_entity(manager, id)
        return
    }

    ship_rotation, ok_rotation := ship_data.rotation.?
    if !ok_rotation {
        log_warn("Failed to spawn bullet because ship rotation nil")
        destroy_entity(manager, id)
        return
    }
    rotation_vector := angle_radians_to_vec(ship_rotation)

    ship_position, ok_position := ship_data.position.?
    if !ok_position {
        log_warn("Failed to spawn bullet because ship position nil")
        destroy_entity(manager, id)
        return
    }

    pos := ship_position + rotation_vector * SHIP_R
    velocity := rotation_vector * BULLET_SPEED

    data_in := Component_Data{
        position = pos,
        velocity = velocity,
        damage = 1,
        is_visible = true,
        color = rl.RAYWHITE,
        render_type = Render_Type.Bullet,
        lifespan = BULLET_LIFESPAN,
    }
    set_component_data(manager, id, data_in)
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
}

jiggle_asteroid_velocity :: proc(vel: Vec2) -> Vec2 {
    speed := linalg.length(vel)
    d_speed :f32= (speed + 10) * 0.1
    jiggled_speed := rand.float32_range(10 + d_speed, 10 + d_speed + speed)

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
    g_mem.game_state = .Between_Levels
    g_mem.score = 0
    g_mem.lives = 3
    g_mem.extra_life_count = 0
    g_mem.beat_level = 0
    restart_timer(&g_mem.death_timer)
    restart_timer(&g_mem.spawn_timer)
    restart_timer(&g_mem.between_levels_timer)
    restart_timer(&g_mem.beat_level_timer)
    restart_timer(&g_mem.ufo_timer)
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

    // TODO: use spawner elsewhere
    spawn_asteroid(.Asteroid_Small, {-50, 100}, {0, -100}, g_mem.manager)
    spawn_asteroid(.Asteroid_Medium, {-100, 100}, {0, -100}, g_mem.manager)
    spawn_asteroid(.Asteroid_Large, {-200, 100}, {0, -100}, g_mem.manager)

    spawn_asteroid(.Asteroid_Small, {0, -50}, {0, 0}, g_mem.manager)
    spawn_asteroid(.Asteroid_Medium, {0, -100}, {0, 0}, g_mem.manager)
    spawn_asteroid(.Asteroid_Large, {0, -200}, {0, 0}, g_mem.manager)
}

update_beat_sound_timer_with_level :: proc(beat_level: i32) {
    g_mem.beat_sound_timer.interval *= INIT_TIMER_INTERVAL_BEAT_SOUND * math.pow(0.8, f32(beat_level))
    g_mem.beat_sound_timer.accum = g_mem.beat_sound_timer.interval
}
