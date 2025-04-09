package game

import "core:fmt"
import rl "vendor:raylib"
import sa "core:container/small_array"
import math "core:math"
import linalg "core:math/linalg"

pr :: fmt.println
Vec2 :: rl.Vector2

WINDOW_W :: 1920
WINDOW_H :: 1080
LOGICAL_W :: 1000
LOGICAL_H :: 1000
PHYSICS_HZ :: 120
DEBUG :: true
FIXED_DT :: 1 / PHYSICS_HZ
MAX_ENTITIES :: 128
N_ASTEROID_SIDES :: 8

Game_Memory :: struct {
	player_id: Entity_Id,
	run: bool,
	using manager: ^Entity_Manager,
}
g_mem: ^Game_Memory

Entity_Id :: distinct u32

Entity_Manager :: struct {
	entities: sa.Small_Array(MAX_ENTITIES, Entity_Id), // len used as active_entity_count, order doesn't align with components
	free_list: sa.Small_Array(MAX_ENTITIES, Entity_Id),
	types: [MAX_ENTITIES]Entity_Type,
	entity_to_index: map[Entity_Id]int,

    // TODO: CSDR moving to a Component_Manager
	using physics: ^Physics_Data,
	using rendering: ^Rendering_Data,
	using gameplay: ^Gameplay_Data,
}

Entity_Type :: enum { 
    None,
    Ship, 
    Asteroid, 
    Bullet, 
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

update :: proc() {
    dt := rl.GetFrameTime()
    update_entities(g_mem.manager, dt)
	if rl.IsKeyPressed(.ESCAPE) {
		g_mem.run = false
	}
}

draw :: proc() {
	rl.BeginDrawing()
	rl.ClearBackground(rl.BLACK)

	rl.BeginMode2D(game_camera())
	draw_entities(g_mem.manager) 
	rl.EndMode2D()

	rl.BeginMode2D(ui_camera())
	draw_debug_ui()
	rl.EndMode2D()

	rl.EndDrawing()
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
	rl.SetWindowPosition(0, 85)
	rl.SetTargetFPS(60)
	rl.SetExitKey(nil)
}

@(export)
game_init :: proc() {
	pr_span("IN game_init")
	g_mem = new(Game_Memory)

	manager := new(Entity_Manager)
	physics := new(Physics_Data)
	manager.physics = physics
	rendering := new(Rendering_Data)
	manager.rendering = rendering
	gameplay := new(Gameplay_Data)
	manager.gameplay = gameplay

	g_mem^ = Game_Memory {
		run = true,
		manager = manager,
	}

	player_id := create_entity(g_mem.manager, .Ship)
    g_mem.player_id = player_id

    create_entity(g_mem.manager, .Asteroid)

	game_hot_reloaded(g_mem)
	pr_span("END game_init")
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
game_hot_reloaded :: proc(mem: rawptr) {
	g_mem = (^Game_Memory)(mem)

	// Here you can also set your own global variables. A good idea is to make
	// your global variables into pointers that point to something inside
	// `g_mem`.
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

draw_entities :: proc(manager: ^Entity_Manager) {
    for index in 0..<get_active_entity_count(manager^) {
        if !manager.is_visibles[index] do continue

        pos := get_position(manager, index)
        rot := get_rotation(manager, index)
        color := get_color(manager, index)

        switch get_render_type(manager, index) {
        case .Ship:
            draw_ship(pos, rot, get_vertices(manager,index), color)
        case .Asteroid:
            radius := get_radius_physics(manager, index)
            draw_asteroid(pos, rot, radius, get_color(manager, index))
        case .Bullet:
            rl.DrawCircleV(pos, 2.0, color)
        case .Particle:
            rl.DrawCircleV(pos, 1.0, color)
        }
    }
}

draw_ship :: proc(pos: Vec2, rot: f32, vertices: Render_Vertices_Component, color: rl.Color) {
    vertices := vertices
    for &vertex in vertices {
        vertex = rotate_point(vertex, {0, 0}, rot) + pos
    }
    for i in 0..<3 {
        rl.DrawLineV(vertices[i], vertices[i+1], color)
    }
    rl.DrawLineV(vertices[3], vertices[0], color)
    rl.DrawPixelV(pos, rl.RED)
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
	pr_span("IN create_entity")

    index := get_active_entity_count(manager^)
	if index > MAX_ENTITIES {
		log_warn("Failed to create entity, max entities reached")
        return 0
	}

    // Get ID from free list or create new
    id: Entity_Id
    if sa.len(manager.free_list) > 0 {
        id = sa.pop_back(&manager.free_list)
    } else {
        id = generate_entity_id(manager^)
    }
    sa.append(&manager.entities, id)

    manager.entity_to_index[id] = index

    // initialize / spawn
    switch type {
    case .Ship:
        init_ship(manager, id, index)
    case .Asteroid:
        init_asteroid(manager, id, index)
    case .Bullet:
        // init_bullet(manager, entity_id, index)
    case .None:
    }

    return id
}

Entity_Data :: struct {
    type: Entity_Type,
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

Entity_Request_Data :: struct {
    type: bool,
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

get_entity_data :: proc(manager: ^Entity_Manager, id: Entity_Id, request: Entity_Request_Data) -> (Entity_Data, bool) {
    index, ok := manager.entity_to_index[id]

    if !ok do return {}, false

    data: Entity_Data
    switch {
    case request.type == true:
        data.type = get_entity_type(manager, index)
    case request.position == true:
        data.position = get_position(manager, index)
    case request.velocity == true:
        data.velocity = get_velocity(manager, index)
    case request.rotation == true:
        data.rotation = get_rotation(manager, index)
    case request.mass == true:
        data.mass = get_mass(manager, index)
    case request.radius_physics == true:
        data.radius_physics = get_radius_physics(manager, index)
    case request.damage == true:
        data.damage = get_damage(manager, index)
    case request.health == true:
        data.health = get_health(manager, index)
    case request.lifespan == true:
        data.lifespan = get_lifespan(manager, index)
    case request.render_type == true:
        data.render_type = get_render_type(manager, index)
    case request.radius_render == true:
        data.radius_render = get_radius_render(manager, index)
    case request.color == true:
        data.color = get_color(manager, index)
    case request.scale == true:
        data.scale = get_scale(manager, index)
    case request.visual_rotation_rate == true:
        data.visual_rotation_rate = get_visual_rotation_rate(manager, index)
    case request.is_visible == true:
        data.is_visible = get_is_visible(manager, index)
    }
    return data, true
}

set_entity_data :: proc(manager: ^Entity_Manager, id: Entity_Id, data: Entity_Data) -> bool {
    idx, ok_idx := manager.entity_to_index[id]

    if !ok_idx do return false

    if data.type == .None {
        log_warn("Failed to create entity, entity_type == None")
        return false
    }
    set_entity_type(manager, idx, data.type)
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

_pop_back_entity :: proc(manager: ^Entity_Manager) -> (Entity_Data, Entity_Id) {
    last_entity := sa.pop_back(&manager.entities)
    last_index := get_last_entity_index(manager^)
    data := Entity_Data{
        type = manager.types[last_index],
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
    return data, last_entity
}

destroy_entity :: proc(manager: ^Entity_Manager, id: Entity_Id) {
    index, ok := manager.entity_to_index[id]

    if !ok do return

    // Get the last active entity. active_count--
    data, last_entity := _pop_back_entity(manager)

    // Swap if entity_destroyed isn't last entity
    if index != sa.len(manager.entities) - 1 {
        set_entity_data(manager, id, data)
    }
    manager.entity_to_index[last_entity] = index

    sa.append(&manager.free_list, id)

    delete_key(&manager.entity_to_index, id)
}

SHIP_ROTATION_MAGNITUDE :: 6
THRUST_MAGNITUDE :: 10
SPACE_FRICTION_COEFFICIENT :: 0.01 // cause of plasma and charged dust
BASE_BRAKING_COEFFICIENT :: 0.01
MIN_SPEED_THRESHOLD :: 350
MAX_BRAKING_EFFECT :: 0.08

update_ship :: proc(manager: ^Entity_Manager, index: int) {
    rot := get_rotation(manager, index)
    pos := get_position(manager, index)
    vel := get_velocity(manager, index)

    d_rot: f32
    if rl.IsKeyDown(.LEFT) || rl.IsKeyDown(.A) {
        d_rot = -SHIP_ROTATION_MAGNITUDE
    }
    if rl.IsKeyDown(.RIGHT) || rl.IsKeyDown(.D) {
        d_rot = SHIP_ROTATION_MAGNITUDE
    }

    is_thrusting := rl.IsKeyDown(.DOWN) || rl.IsKeyDown(.S)

    dt := rl.GetFrameTime()
    rot += d_rot * dt
    heading : Vec2 = {math.cos(rot), math.sin(rot)} // aka facing, not ship velocity nor direction of movement of body

    vel_thrust_term : Vec2 = is_thrusting ? THRUST_MAGNITUDE * heading : 0
    vel_space_friction_term : Vec2 = vel * SPACE_FRICTION_COEFFICIENT

    speed := linalg.length(vel)
    braking_factor : f32 = 0
    if speed > 0 {
        braking_factor = min(BASE_BRAKING_COEFFICIENT * (MIN_SPEED_THRESHOLD / (speed + 10)), MAX_BRAKING_EFFECT)
    }
    vel_braking_friction_term := vel * braking_factor

    vel += vel_thrust_term - vel_space_friction_term - vel_braking_friction_term
    pos += vel * dt

    set_rotation(manager, index, rot)
    set_position(manager, index, pos)
    set_velocity(manager, index, vel)
}

update_entities :: proc(manager: ^Entity_Manager, dt: f32) {
	for index in 0..<get_active_entity_count(manager^) {
        entity_type := get_entity_type(manager, index)
        switch entity_type {
		case .Ship:
            update_ship(manager, index)
		case .Asteroid:
            visual_rotation_rate := get_visual_rotation_rate(manager, index)
            rot := get_rotation(manager, index)
            set_rotation(manager, index, rot + visual_rotation_rate)
		case .Bullet:
			// lifespan := sa.get(manager.gameplay.lifespans, i)
			// new_lifespan := lifespan - dt
			// sa.set(&manager.gameplay.lifespans, i, new_lifespan)
			// if sa.get(manager.gameplay.lifespans, i) <= 0 {
			// 	destroy_entity(manager, sa.get(manager.entities, i))
			// }
        case .None:
		}
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

draw_debug_ui :: proc() {
    vel := get_velocity(g_mem.manager, 0)
    speed := linalg.length(vel)
    if DEBUG {
        rl.DrawText(
            fmt.ctprintf(
                "fps: %v\nwin: %vx%v\nlogical: %vx%v\ndt_running: %v\npos: %v\nvel: %v\nspeed: %v\nhp: %v",
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
            3, 150, 12, rl.WHITE,
        )
    }
}

get_player_id :: proc() -> Entity_Id {
	return g_mem.player_id
}

player_idx :: proc() -> int {
	idx, ok := g_mem.manager.entity_to_index[g_mem.player_id]
	if ok {
		return idx
	}
	log_warn("Player entity id not in entity_to_index map")
	return -1
}

screen_left :: proc() -> f32 {
	return game_camera().target.x + game_camera().offset.x
}
screen_right :: proc() -> f32 {
	return game_camera().target.x + game_camera().offset.x + LOGICAL_W,
}
screen_top :: proc() -> f32 {
	return 0
}
screen_bottom :: proc() -> f32 {
	return LOGICAL_H
}

pr_span :: proc(msg: Maybe(string)) {
    pr("-----------------------", msg.? or_else "", "-----------------------")
}

log_warn :: proc(msg: Maybe(string), loc := #caller_location) {
	fmt.printfln("[%v]WARN: %v", loc, msg.? or_else "")
}

init_ship :: proc(manager: ^Entity_Manager, id: Entity_Id, index: int) {
    R :: 20
    position := Vec2{0,0}
    rotation : f32 = math.to_radians(f32(0))

    tail_angle := math.to_radians(f32(45))
    vertices: Render_Vertices_Component
    vertices[0] = Vec2{R, 0}
    vertices[1] =  Vec2{-R*math.cos(tail_angle), -R*math.sin(tail_angle)}
    vertices[2] =  Vec2{-R*0.25, 0}
    vertices[3] =  Vec2{-R*math.cos(tail_angle), R*math.sin(tail_angle)}

    set_entity_data(manager, id, Entity_Data{
        type = .Ship,
        position = position,
        rotation = rotation,
        velocity = Vec2{0, 0},
        radius_physics = R,
        render_type = Render_Type.Ship,
        color = rl.GREEN,
        radius_render = R,
        damage = 1,
        health = 5,
        is_visible = true,
        vertices = vertices,
    })
}

init_asteroid :: proc(manager: ^Entity_Manager, id: Entity_Id, index: int) {
    RADIUS :: 25
    data_in := Entity_Data{
        type = .Asteroid,
        position = Vec2{250,250},
        velocity = Vec2{-25, -45},
        radius_physics = RADIUS,
        render_type = Render_Type.Asteroid,
        color = rl.GRAY,
        radius_render = RADIUS,
        visual_rotation_rate = .8,
        health = 3,
        is_visible = true,
    }
    set_entity_data(manager, id, data_in)
}

