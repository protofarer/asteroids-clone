package game

import "core:fmt"
import linalg "core:math/linalg"
import rl "vendor:raylib"
import sa "core:container/small_array"

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

Game_Memory :: struct {
	player_id: Entity_Id,
	run: bool,
	using manager: ^Entity_Manager,
}
g_mem: ^Game_Memory

Physics_Data :: struct {
	positions: sa.Small_Array(MAX_ENTITIES, Vec2),
	velocities: sa.Small_Array(MAX_ENTITIES, Vec2),
	rotations: sa.Small_Array(MAX_ENTITIES, f32),
	masses: sa.Small_Array(MAX_ENTITIES, f32),
	radii: sa.Small_Array(MAX_ENTITIES, f32),
}

Gameplay_Data :: struct {
	lifespans: sa.Small_Array(MAX_ENTITIES, f32),
	damages: sa.Small_Array(MAX_ENTITIES, i32),
	healths: sa.Small_Array(MAX_ENTITIES, i32),
}

Rendering_Data :: struct {
	// models: []Model,
	types: sa.Small_Array(MAX_ENTITIES, Render_Type),
	vertices: sa.Small_Array(MAX_ENTITIES, []Vec2),
	radii: sa.Small_Array(MAX_ENTITIES, f32),
	colors: sa.Small_Array(MAX_ENTITIES, rl.Color),
	rotation_offsets: sa.Small_Array(MAX_ENTITIES, f32), // asteroid visual rotation
	is_visible: sa.Small_Array(MAX_ENTITIES, bool),
	scales: sa.Small_Array(MAX_ENTITIES, f32),
}

Render_Type :: enum {
	Ship,
	Asteroid,
	Bullet,
	Particle,
}

Entity_Id :: distinct u32

Entity_Manager :: struct {
	active_count: int,
	entities: sa.Small_Array(MAX_ENTITIES, Entity_Id),
	entity_to_index: map[Entity_Id]int,
	free_list: sa.Small_Array(MAX_ENTITIES, Entity_Id),
	types: sa.Small_Array(MAX_ENTITIES, Entity_Type),

	physics: ^Physics_Data,
	rendering: ^Rendering_Data,
	gameplay: ^Gameplay_Data,
}

Entity_Type :: enum { Ship, Asteroid, Bullet, }

game_camera :: proc() -> rl.Camera2D {
	w := f32(rl.GetScreenWidth())
	h := f32(rl.GetScreenHeight())

	return {
		zoom = h/LOGICAL_H,
		// target = g_mem.player_pos,
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
	draw_entities(g_mem.physics, g_mem.rendering) 
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

draw_entities :: proc(physics: ^Physics_Data, rendering: ^Rendering_Data) {
    for i := 0; i < sa.len(rendering.types); i += 1 {
        if !sa.get(rendering.is_visible, i) do continue

        // Get the entity's position and rotation from physics
        pos := sa.get(physics.positions, i)
        rot := sa.get(physics.rotations, i)

        // Draw based on render type
        switch sa.get(rendering.types, i) {
        case .Ship:
            draw_ship(pos, rot, sa.get(rendering.vertices, i), sa.get(rendering.colors, i))
        case .Asteroid:
            radius := sa.get(rendering.radii, i)
            draw_asteroid(pos, rot, radius, sa.get(rendering.colors, i))
        case .Bullet:
            rl.DrawCircleV(pos, 2.0, sa.get(rendering.colors, i))
        case .Particle:
            rl.DrawCircleV(pos, 1.0, sa.get(rendering.colors, i))
        }
    }
}

draw_ship :: proc(pos: rl.Vector2, rot: f32, vertices: []rl.Vector2, color: rl.Color) {
	rl.DrawCircleV(pos, 15, rl.GREEN)
  // // Apply rotation and translation to vertices
  // transformed_vertices := make([]rl.Vector2, len(vertices))
  // defer delete(transformed_vertices)
  //
  // for i := 0; i < len(vertices); i += 1 {
  //   // Rotate and translate vertices
  //   transformed_vertices[i] = rotate_point(vertices[i], rot)
  //   transformed_vertices[i] = {
  //     transformed_vertices[i].x + pos.x,
  //     transformed_vertices[i].y + pos.y,
  //   }
  // }
  //
  // // TODO
  // // rl.DrawTriangleLines()
  // // define a center to rotate around, transform vertices
  // //////////////////////////
  //
  // // Draw lines between vertices
  // for i := 0; i < len(transformed_vertices)-1; i += 1 {
  //   rl.DrawLineV(transformed_vertices[i], transformed_vertices[i+1], color)
  // }
  // // Connect last vertex to first
  // rl.DrawLineV(transformed_vertices[len(transformed_vertices)-1], transformed_vertices[0], color)
}

append_zero_value_all_components :: proc(manager: ^Entity_Manager) {
    sa.append(&manager.physics.positions, Vec2{})
    sa.append(&manager.physics.velocities, Vec2{})
    sa.append(&manager.physics.rotations, 0)
    sa.append(&manager.physics.masses, 0)
    sa.append(&manager.physics.radii, 0)

    sa.append(&manager.gameplay.lifespans, 0)
    sa.append(&manager.gameplay.damages, 0)
    sa.append(&manager.gameplay.healths, 0)

    sa.append(&manager.rendering.types, Render_Type.Ship)
    sa.append(&manager.rendering.vertices, nil)
    sa.append(&manager.rendering.colors, rl.WHITE)
    sa.append(&manager.rendering.rotation_offsets, 0)
    sa.append(&manager.rendering.is_visible, true)
    sa.append(&manager.rendering.scales, 1)
}

create_entity :: proc(manager: ^Entity_Manager, type: Entity_Type) -> Entity_Id {
	pr_span("IN create_entity")
    entity_id: Entity_Id
    
    // Get ID from free list or create new
    if sa.len(manager.free_list) > 0 {
        entity_id = sa.pop_back(&manager.free_list)
    } else {
        entity_id = Entity_Id(sa.len(manager.entities))
        sa.append(&manager.entities, entity_id)
        append_zero_value_all_components(manager)
    }
    
    index := manager.active_count
	if index > MAX_ENTITIES {
		log_warn("Cannot create entity, max entities reached")
	}
    manager.entity_to_index[entity_id] = index
    manager.active_count += 1
    
    // Set entity type
	sa.set(&manager.types, index, type)
    
    // Initialize based on type
    switch type {
    case .Ship:
        init_ship(manager, entity_id, index)
    case .Asteroid:
        init_asteroid(manager, entity_id, index)
    case .Bullet:
        // init_bullet(manager, entity_id, index)
    }
    
    return entity_id
}

log_warn :: proc(msg: string, loc := #caller_location) {
	fmt.printfln("[%v]WARN: %v", loc, msg)
}

init_ship :: proc(manager: ^Entity_Manager, id: Entity_Id, index: int) {
	pr("IN init_ship")

// Physics_Data :: struct {
// 	positions: [dynamic]Vec2,
// 	velocities: [dynamic]Vec2,
// 	rotations: [dynamic]f32,
// 	masses: [dynamic]f32,
// 	radii: [dynamic]f32,
// }
//
// Gameplay_Data :: struct {
// 	lifespan: [dynamic]f32,
// 	damage: [dynamic]i32,
// 	health: [dynamic]i32,
// }
//
// Rendering_Data :: struct {
// 	// models: []Model,
// 	types: [dynamic]Render_Type,
// 	vertices: [dynamic][]Vec2,
// 	colors: [dynamic]rl.Color,
// 	rotation_offsets: [dynamic]f32, // asteroid visual rotation
// 	is_visible: [dynamic]bool,
// 	scales: [dynamic]f32,
// }
}

init_asteroid :: proc(manager: ^Entity_Manager, id: Entity_Id, index: int) {
	pr_span("IN init_asteroid")
    radius :: 25
    sa.set(&manager.physics.positions, index,Vec2{ 250, 250})
    sa.set(&manager.physics.rotations, index,0)
    sa.set(&manager.physics.radii, index, radius)
    sa.set(&manager.rendering.types, index, Render_Type.Asteroid)
    sa.set(&manager.rendering.colors, index, rl.GRAY)
    sa.set(&manager.rendering.radii, index, radius)
    sa.set(&manager.rendering.rotation_offsets, index, .8)
    sa.set(&manager.gameplay.healths, index, 3)
// Physics_Data :: struct {
// 	positions: [dynamic]Vec2,
// 	velocities: [dynamic]Vec2,
// 	rotations: [dynamic]f32,
// 	masses: [dynamic]f32,
// 	radii: [dynamic]f32,
// }
//
// Gameplay_Data :: struct {
// 	lifespan: [dynamic]f32,
// 	damage: [dynamic]i32,
// 	health: [dynamic]i32,
// }
//
// Rendering_Data :: struct {
// 	// models: []Model,
// 	types: [dynamic]Render_Type,
// 	vertices: [dynamic][]Vec2,
//  radii:
// 	colors: [dynamic]rl.Color,
// 	rotation_offsets: [dynamic]f32, // asteroid visual rotation
// 	is_visible: [dynamic]bool,
// 	scales: [dynamic]f32,
// }

}

// Remove an entity
destroy_entity :: proc(manager: ^Entity_Manager, entity: Entity_Id) {
    index, ok := manager.entity_to_index[entity]
    if !ok do return
    
    // Get the last active entity
    last_index := manager.active_count - 1
    last_entity := sa.get(manager.entities, last_index)
    
    // Move the last entity to the position of the removed entity
    if index != last_index {
        // Swap component data
		last_position := sa.get(manager.physics.positions, last_index)
        sa.set(&manager.physics.positions, index, last_position)

		last_rendering_type := sa.get(manager.rendering.types, last_index)
        sa.set(&manager.rendering.types, index, last_rendering_type)

        // TODO: etc. for all components
        
        // Update index lookup
        manager.entity_to_index[last_entity] = index
    }
    
    // Decrement active count
    manager.active_count -= 1
    
    // Add to free list for recycling
    sa.append(&manager.free_list, entity)
    
    // Remove from lookup
    delete_key(&manager.entity_to_index, entity)
}

update_entities :: proc(manager: ^Entity_Manager, dt: f32) {
	for i := 0; i < manager.active_count; i += 1 {
		switch sa.get(manager.types, i) {
		case .Ship:
            input: rl.Vector2
            if rl.IsKeyDown(.UP) || rl.IsKeyDown(.W) {
                input.y -= 1
            }
            if rl.IsKeyDown(.DOWN) || rl.IsKeyDown(.S) {
                input.y += 1
            }
            if rl.IsKeyDown(.LEFT) || rl.IsKeyDown(.A) {
                input.x -= 1
            }
            if rl.IsKeyDown(.RIGHT) || rl.IsKeyDown(.D) {
                input.x += 1
            }

            input = linalg.normalize0(input)
            pos := sa.get(manager.physics.positions, i)
            sa.set(&manager.physics.positions, i, pos + input*10)
			// update_ship(manager, i, dt)
		case .Asteroid:
			// update_asteroid(manager, i, dt)
            rotation_offset := sa.get(manager.rendering.rotation_offsets, i)
            rot := sa.get(manager.physics.rotations, i)
            sa.set(&manager.physics.rotations, i, rot + rotation_offset)
		case .Bullet:
			// update_bullet(manager, i, dt)

			lifespan := sa.get(manager.gameplay.lifespans, i)
			new_lifespan := lifespan - dt
			sa.set(&manager.gameplay.lifespans, i, new_lifespan)
			if sa.get(manager.gameplay.lifespans, i) <= 0 {
				destroy_entity(manager, sa.get(manager.entities, i))
			}
		}
	}
}

draw_asteroid :: proc(pos: Vec2, rot: f32, radius: f32, color: rl.Color) {
	// rl.DrawCircleV(pos, radius, color)
    rl.DrawPolyLines(pos, 5, radius, rot,  color)
}

draw_debug_ui :: proc() {
    if DEBUG {
        rl.DrawText(
            fmt.ctprintf(
                "fps: %v\nwin: %vx%v\nlogical: %vx%v\ndt_running: %v\npos: %v\nvel: %v\nhp: %v",
                rl.GetFPS(),
                rl.GetScreenWidth(),
                rl.GetScreenHeight(),
                LOGICAL_H,
                LOGICAL_W,
                rl.GetTime(),
                sa.get(g_mem.physics.positions, 0),
                sa.get(g_mem.physics.velocities, 0),
				sa.get(g_mem.gameplay.healths, 0),
            ),
            3, 3, 16, rl.WHITE,
        )
        rl.DrawText(
            fmt.ctprintf(
                "cam.tar: %v\ncam.off: %v\nscreen_left: %v\nscreen_right: %v",
                game_camera().target,
                game_camera().offset,
                screen_left(),
                screen_right(),
            ),
            3, 150, 16, rl.WHITE,
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

pr_span :: proc(msg: string) {
    pr("-----------------------", msg, "-----------------------")
}
