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
LOGICAL_H :: 1000

PHYSICS_HZ :: 120
FIXED_DT :: 1 / PHYSICS_HZ

MAX_ENTITIES :: 128
N_ASTEROID_SIDES :: 8
SMALL_ASTEROID_RADIUS :: 10

SHIP_R :: 15
SHIP_ROTATION_MAGNITUDE :: 3
THRUST_MAGNITUDE :: 10
SPACE_FRICTION_COEFFICIENT :: 0.01 // cause of plasma and charged dust

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

Asteroid_Kind :: enum {
    Small,
    Medium,
    Large,
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
	if rl.IsKeyPressed(.ESCAPE) {
		g_mem.run = false
	}
    dt := rl.GetFrameTime()
    update_entities(g_mem.manager, dt)
}

draw :: proc() {
	rl.BeginDrawing()
	rl.ClearBackground(rl.BLACK)

	rl.BeginMode2D(game_camera())
    draw_screen_edges()
	draw_entities(g_mem.manager) 
	rl.EndMode2D()

	rl.BeginMode2D(ui_camera())
	draw_debug_ui()
	rl.EndMode2D()

	rl.EndDrawing()
}
screen_edge_left :: proc() -> i32 {
    return i32(screen_left() + 1)
}
screen_edge_top :: proc() -> i32 {
    return i32(screen_top() + 1)
}
screen_edge_right :: proc() -> i32 {
    return i32(screen_edge_left() + LOGICAL_W - 2)
}
screen_edge_bottom :: proc() -> i32 {
    return i32(screen_edge_top() + LOGICAL_H - 2)
}

draw_screen_edges :: proc() {
    rl.DrawRectangleLines(screen_edge_left(), screen_edge_top(), LOGICAL_W - 2, LOGICAL_H - 2, rl.BLUE)
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

	player_id := spawn_ship({0,0}, math.to_radians(f32(-90)), g_mem.manager)
    g_mem.player_id = player_id
    pr("init player_id", player_id)

    spawn_asteroid(.Small, {0, -100}, {0, -100}, g_mem.manager)

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
game_shutdown :: proc() { free(g_mem) }
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
    if DEBUG do rl.DrawPixelV(pos, rl.RED)
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

// CSDR return false for failure
create_entity :: proc(manager: ^Entity_Manager, type: Entity_Type) -> Entity_Id {
	pr_span("IN create_entity")

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
    if rl.IsKeyPressed(.SPACE) {
        spawn_bullet_from_ship(manager)
    }

    is_thrusting := rl.IsKeyDown(.DOWN) || rl.IsKeyDown(.S)

    dt := rl.GetFrameTime()
    rot += d_rot * dt
    heading : Vec2 = {math.cos(rot), math.sin(rot)} // aka facing, not ship velocity nor direction of movement of body

    vel_thrust_term : Vec2 = is_thrusting ? THRUST_MAGNITUDE * heading : 0
    vel_space_friction_term : Vec2 = vel * SPACE_FRICTION_COEFFICIENT

    speed := linalg.length(vel)
    if !is_thrusting && speed > 0 && speed < 30 {
        braking_factor := 1 / (speed + 10)
        vel -= vel * braking_factor
        if linalg.length(vel) < 1 {
            vel = 0
        }
    }

    vel += vel_thrust_term - vel_space_friction_term
    pos += vel * dt

    set_rotation(manager, index, rot)
    set_position(manager, index, pos)
    set_velocity(manager, index, vel)
}

update_entities :: proc(manager: ^Entity_Manager, dt: f32) {
    // pr("entities:",sa.slice(&manager.entities)[:(sa.len(manager.entities))])
    // pr("entity_to_idx:",manager.entity_to_index)
    // pr("free_list:",sa.slice(&manager.free_list)[:(sa.len(manager.free_list))])
    // pr_span("")
    entities_to_destroy: [dynamic]int
    defer delete(entities_to_destroy)

	for index in 0..<get_active_entity_count(manager^) {
        entity_type := get_entity_type(manager, index)
        switch entity_type {
		case .Ship:
            update_ship(manager, index)
		case .Asteroid:
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

            lifespan := get_lifespan(manager, index)
            lifespan -= dt
			if lifespan <= 0 {
                append(&entities_to_destroy, index)
			} else {
                set_lifespan(manager, index, lifespan)
            }
        case .None:
		}
        pos := get_position(manager, index)
        if pos.x <= f32(screen_edge_left()) {
            set_position(manager, index, {f32(screen_edge_right() - 1), pos.y})
        } else if pos.x >= f32(screen_edge_right()) {
            set_position(manager, index, {f32(screen_edge_left() + 1), pos.y})
        }
        if pos.y <= f32(screen_edge_top()) {
            set_position(manager, index, {pos.x, f32(screen_edge_bottom() - 1)})
        } else if pos.y >= f32(screen_edge_bottom()) {
            set_position(manager, index, {pos.x, f32(screen_edge_top() + 1)})
        }
	}

    for index in entities_to_destroy {
        pr("index to destroy", index)
        id := sa.get(manager.entities, index)
        pr("id to destroy", id)
        destroy_entity(manager, id)
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
                "fps: %v\nwin: %vx%v\nlogical: %vx%v\ndt_running: %v\npos: %v\nvel: %v\nspeed: %v\nhp: %v\nactive_entities: %v\nentities: %v\nfree_list: %v",
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
            i32(rl.GetScreenWidth() - 300), 3, 12, rl.WHITE,
        )
    }
}

get_player_id :: proc() -> Entity_Id {
	return g_mem.player_id
}

player_index :: proc() -> int {
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

    tail_angle := math.to_radians(f32(45))
    vertices: Render_Vertices_Component
    vertices[0] = Vec2{SHIP_R, 0}
    vertices[1] =  Vec2{-SHIP_R*math.cos(tail_angle), -SHIP_R*math.sin(tail_angle)}
    vertices[2] =  Vec2{-SHIP_R*0.25, 0}
    vertices[3] =  Vec2{-SHIP_R*math.cos(tail_angle), SHIP_R*math.sin(tail_angle)}

    set_component_data(manager, id, Component_Data{
        position = pos,
        rotation = rot,
        velocity = Vec2{0, 0},
        radius_physics = SHIP_R,
        render_type = Render_Type.Ship,
        color = rl.GREEN,
        radius_render = SHIP_R,
        damage = 1,
        health = 5,
        is_visible = true,
        vertices = vertices,
    })
    return id
}

spawn_asteroid :: proc(kind: Asteroid_Kind, pos: Vec2, vel: Vec2, manager: ^Entity_Manager) {
    id := create_entity(manager, .Asteroid)
    visual_rotation_rate := rand.float32_range(0.1, 1.5)
    radius: f32
    switch kind {
    case .Small:
        radius = SMALL_ASTEROID_RADIUS
    case .Medium:
        radius = SMALL_ASTEROID_RADIUS * 1.5
    case .Large:
        radius = SMALL_ASTEROID_RADIUS * 2.5
    }
    data_in := Component_Data{
        position = pos,
        velocity = vel,
        radius_physics = radius,
        render_type = Render_Type.Asteroid,
        color = rl.GRAY,
        radius_render = radius,
        visual_rotation_rate = visual_rotation_rate,
        health = 3,
        is_visible = true,
    }
    set_component_data(manager, id, data_in)
}

spawn_bullet_from_ship :: proc(manager: ^Entity_Manager) {
    id := create_entity(manager, .Bullet)
    BULLET_SPEED :: 700
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
        color = rl.RED,
        render_type = Render_Type.Bullet,
        lifespan = 1,
    }
    set_component_data(manager, id, data_in)
}

angle_radians_to_vec :: proc(rot: f32) -> Vec2 {
    return Vec2{math.cos(rot), math.sin(rot)}
}
