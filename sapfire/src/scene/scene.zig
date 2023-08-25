const ecs = @import("zflecs");
const zgpu = @import("zgpu");
const zgui = @import("zgui");
const zm = @import("zmath");
const std = @import("std");
const json = std.json;
const comps = @import("components.zig");
const tags = @import("tags.zig");
const Transform = comps.Transform;
const Mesh = comps.Mesh;
const TestTag = tags.TestTag;
const fs = std.fs;
const sf = struct {
    usingnamespace @import("../core.zig");
    usingnamespace @import("../rendering.zig");
};
const log = sf.log;
const asset = sf.AssetManager;
const Material = sf.Material;

const ComponentValueTag = enum { matrix, vector, path, guid, matrix3 };

const ParseComponent = struct {
    name: [:0]const u8,
    value: union(ComponentValueTag) {
        matrix: [16]f32,
        vector: [3]f32,
        path: [:0]const u8,
        guid: [64]u8,
        matrix3: [9]f32,
    },
};

const ParseEntity = struct {
    name: [:0]const u8,
    path: [:0]const u8,
    id: u64,
    components: []const ParseComponent,
    tags: [][:0]const u8,
};

const ParseWorld = struct {
    entities: []const ParseEntity,
    tags: [][:0]const u8,
    components: [][:0]const u8,
};

pub const SceneConfig = struct {
    textures: [][:0]const u8,
    materials: [][:0]const u8,
    meshes: [][:0]const u8,
    world: ParseWorld,
};

const ParseScene = struct {
    world: ParseWorld,
    texture_paths: [][:0]const u8,
    material_paths: [][:0]const u8,
    geometry_paths: [][:0]const u8,
};

pub const SceneAsset = struct {
    guid: [64]u8,
    texture_paths: std.ArrayList([:0]const u8),
    material_paths: std.ArrayList([:0]const u8),
    geometry_paths: std.ArrayList([:0]const u8),
    world: ?ParseWorld = null,

    pub fn create_empty(database_allocator: std.mem.Allocator, path: [:0]const u8) !SceneAsset {
        const scene_guid = sf.AssetManager.generate_guid(path);
        var texture_paths = try std.ArrayList([:0]const u8).initCapacity(database_allocator, 256);
        var geometry_paths = try std.ArrayList([:0]const u8).initCapacity(database_allocator, 256);
        var material_paths = try std.ArrayList([:0]const u8).initCapacity(database_allocator, 256);
        return SceneAsset{
            .guid = scene_guid,
            .texture_paths = texture_paths,
            .material_paths = material_paths,
            .geometry_paths = geometry_paths,
        };
    }

    pub fn create(database_allocator: std.mem.Allocator, parse_allocator: std.mem.Allocator, path: [:0]const u8) !SceneAsset {
        const scene_guid = sf.AssetManager.generate_guid(path);
        const config_data = std.fs.cwd().readFileAlloc(parse_allocator, path, 512 * 16) catch |e| {
            log.err("Failed to parse scene config file. Given path:{s}", .{path});
            return e;
        };
        const config = try json.parseFromSliceLeaky(ParseScene, database_allocator, config_data, .{});
        var texture_paths = try std.ArrayList([:0]const u8).initCapacity(database_allocator, 256);
        var geometry_paths = try std.ArrayList([:0]const u8).initCapacity(database_allocator, 256);
        var material_paths = try std.ArrayList([:0]const u8).initCapacity(database_allocator, 256);
        for (config.texture_paths) |t_path| {
            try texture_paths.append(t_path);
        }
        for (config.material_paths) |m_path| {
            try material_paths.append(m_path);
        }
        for (config.geometry_paths) |g_path| {
            try geometry_paths.append(g_path);
        }
        return SceneAsset{
            .guid = scene_guid,
            .texture_paths = texture_paths,
            .material_paths = material_paths,
            .geometry_paths = geometry_paths,
            .world = config.world,
        };
    }
};

pub const Scene = struct {
    guid: [64]u8,
    world: World,
    asset: SceneAsset,
    arena: std.heap.ArenaAllocator,
    scene_entity: ecs.entity_t,
    vertices: std.ArrayList(sf.Vertex),
    indices: std.ArrayList(u32),
    pipeline_system: sf.PipelineSystem,
    mesh_manager: sf.MeshManager,
    texture_manager: sf.TextureManager,
    material_manager: sf.MaterialManager,
    global_uniform_bind_group: zgpu.BindGroupHandle,
    vertex_buffer: sf.Buffer,
    index_buffer: sf.Buffer,

    pub var scene: ?*Scene = null;
    pub var currently_selected_entity: ecs.entity_t = undefined;
    const INIT_INDEX_ARRAY_CAPACITY = 262144;
    const INIT_VERTEX_ARRAY_CAPACITY = 262144;

    pub fn create_new(allocator: std.mem.Allocator, gctx: *zgpu.GraphicsContext, path: [:0]const u8) !Scene {
        _ = gctx;
        var arena = std.heap.ArenaAllocator.init(allocator);
        var scene_asset = try SceneAsset.create_empty(allocator, path);
        var world = try World.init(arena.allocator());
        var texman = try sf.TextureManager.init_empty(allocator);
        var matman = try sf.MaterialManager.init_empty(allocator);
        var meshman = try sf.MeshManager.init_empty(allocator);
        var pipeline_system = try sf.PipelineSystem.init(allocator);
        var vertices = std.ArrayList(sf.Vertex).init(allocator);
        try vertices.ensureTotalCapacity(INIT_VERTEX_ARRAY_CAPACITY);
        var indices = std.ArrayList(u32).init(allocator);
        try indices.ensureTotalCapacity(INIT_INDEX_ARRAY_CAPACITY);
        return Scene{
            .guid = sf.AssetManager.generate_guid(path),
            .world = world,
            .asset = scene_asset,
            .arena = arena,
            .vertices = vertices,
            .indices = indices,
            .pipeline_system = pipeline_system,
            .mesh_manager = meshman,
            .texture_manager = texman,
            .material_manager = matman,
            .global_uniform_bind_group = undefined,
            .vertex_buffer = undefined,
            .index_buffer = undefined,
            .scene_entity = undefined,
        };
    }

    pub fn deserialize(self: *Scene, gctx: *zgpu.GraphicsContext, meshes: *std.ArrayList(Mesh)) !void {
        const global_uniform_bgl = gctx.createBindGroupLayout(&.{
            zgpu.bufferEntry(0, .{ .vertex = true, .fragment = true }, .uniform, true, 0),
        });
        defer gctx.releaseResource(global_uniform_bgl);
        self.global_uniform_bind_group = gctx.createBindGroup(global_uniform_bgl, &.{
            .{
                .binding = 0,
                .buffer_handle = gctx.uniforms.buffer,
                .offset = 0,
                .size = @sizeOf(sf.GlobalUniforms),
            },
        });
        self.scene_entity = try self.world.deserialize(
            &self.asset,
            gctx,
            global_uniform_bgl,
            &self.pipeline_system,
            &self.texture_manager,
            &self.material_manager,
            &self.mesh_manager,
            meshes,
            &self.vertices,
            &self.indices,
        );
        currently_selected_entity = self.scene_entity;
        self.vertex_buffer = sf.Buffer.create_and_load(gctx, .{ .copy_dst = true, .vertex = true }, sf.Vertex, self.vertices.items);
        self.index_buffer = sf.Buffer.create_and_load(gctx, .{ .copy_dst = true, .index = true }, u32, self.indices.items);
        var update_transforms_system = @import("systems/update_transforms_system.zig").system();
        ecs.SYSTEM(self.world.id, "Local to world transforms", ecs.PreUpdate, &update_transforms_system);
        var render_color_system = @import("systems/render_color_system.zig").system();
        ecs.SYSTEM(self.world.id, "render", ecs.OnStore, &render_color_system);
    }

    pub fn create(allocator: std.mem.Allocator, gctx: *zgpu.GraphicsContext, path: [:0]const u8) !Scene {
        var arena = std.heap.ArenaAllocator.init(allocator);
        var world = try World.init(arena.allocator());
        var parse_arena = std.heap.ArenaAllocator.init(allocator);
        defer parse_arena.deinit();
        const scene_asset = try SceneAsset.create(arena.allocator(), parse_arena.allocator(), path);
        // manager inits can be jobified
        var texman = try sf.TextureManager.init_from_slice(arena.allocator(), scene_asset.texture_paths.items);
        var matman = try sf.MaterialManager.init_from_slice(arena.allocator(), scene_asset.material_paths.items);
        var meshman = try sf.MeshManager.init_from_slice(arena.allocator(), scene_asset.geometry_paths.items);
        var meshes = std.ArrayList(Mesh).init(arena.allocator());
        try meshes.ensureTotalCapacity(128);
        var vertices = std.ArrayList(sf.Vertex).init(arena.allocator());
        try vertices.ensureTotalCapacity(INIT_VERTEX_ARRAY_CAPACITY);
        var indices = std.ArrayList(u32).init(arena.allocator());
        try indices.ensureTotalCapacity(INIT_INDEX_ARRAY_CAPACITY);
        var pipeline_system = try sf.PipelineSystem.init(arena.allocator());
        const global_uniform_bgl = gctx.createBindGroupLayout(&.{
            zgpu.bufferEntry(0, .{ .vertex = true, .fragment = true }, .uniform, true, 0),
        });
        defer gctx.releaseResource(global_uniform_bgl);
        const global_uniform_bind_group = gctx.createBindGroup(global_uniform_bgl, &.{
            .{
                .binding = 0,
                .buffer_handle = gctx.uniforms.buffer,
                .offset = 0,
                .size = @sizeOf(sf.GlobalUniforms),
            },
        });
        const scene_entity = try world.deserialize(&scene_asset, gctx, global_uniform_bgl, &pipeline_system, &texman, &matman, &meshman, &meshes, &vertices, &indices);
        currently_selected_entity = scene_entity;
        const vertex_buffer = sf.Buffer.create_and_load(gctx, .{ .copy_dst = true, .vertex = true }, sf.Vertex, vertices.items);
        const index_buffer = sf.Buffer.create_and_load(gctx, .{ .copy_dst = true, .index = true }, u32, indices.items);
        var update_transforms_system = @import("systems/update_transforms_system.zig").system();
        ecs.SYSTEM(world.id, "Local to world transforms", ecs.PreUpdate, &update_transforms_system);
        var render_color_system = @import("systems/render_color_system.zig").system();
        ecs.SYSTEM(world.id, "render", ecs.OnStore, &render_color_system);
        return Scene{
            .guid = sf.AssetManager.generate_guid(path),
            .world = world,
            .asset = scene_asset,
            .arena = arena,
            .scene_entity = scene_entity,
            .vertices = vertices,
            .indices = indices,
            .pipeline_system = pipeline_system,
            .mesh_manager = meshman,
            .texture_manager = texman,
            .material_manager = matman,
            .global_uniform_bind_group = global_uniform_bind_group,
            .vertex_buffer = vertex_buffer,
            .index_buffer = index_buffer,
        };
    }

    pub fn recreate_buffers(self: *Scene) void {
        const gctx = sf.RendererState.renderer.?.gctx;
        gctx.releaseResource(self.index_buffer.handle);
        gctx.releaseResource(self.vertex_buffer.handle);
        self.vertex_buffer = sf.Buffer.create_and_load(gctx, .{ .copy_dst = true, .vertex = true }, sf.Vertex, self.vertices.items);
        self.index_buffer = sf.Buffer.create_and_load(gctx, .{ .copy_dst = true, .index = true }, u32, self.indices.items);
    }

    pub fn progress(self: *Scene, delta_time: f32) !void {
        _ = ecs.progress(self.world.id, delta_time);
    }

    pub fn update_no_systems(self: *Scene, delta_time: f32) !void {
        _ = delta_time;
        { // update transforms
            var query_desc = ecs.query_desc_t{};
            query_desc.filter.terms[0] = .{ .id = ecs.id(Transform) };
            var q = try ecs.query_init(self.world.id, &query_desc);
            var it = ecs.query_iter(self.world.id, q);
            while (ecs.query_next(&it)) {
                const entities = it.entities();
                for (0..it.count()) |i| {
                    if (ecs.field(&it, Transform, 1)) |transforms| {
                        const parent = World.entity_get_parent_world_id(it.world, entities[i]);
                        if (parent > 0) { // This is to prevent root modification
                            const parent_transform = ecs.get(it.world, parent, Transform) orelse continue;
                            transforms[i].world = zm.mul(transforms[i].local, parent_transform.world);
                        }
                    }
                }
            }
        }
    }

    pub fn destroy(self: *Scene) void {
        // self.vertices.deinit();
        // self.indices.deinit();
        self.world.deinit();
        self.arena.deinit();
    }

    // TODO: this should be in the editor
    pub fn draw_scene_hierarchy(self: *Scene) void {
        if (zgui.begin("Hierarchy", .{})) {
            const root_entity = ecs.lookup(self.world.id, "Root");
            if (root_entity > 0) {
                if (zgui.treeNodeFlags("Root", .{})) {
                    draw_children_nodes(self, root_entity);
                    zgui.treePop();
                }
            }
            if (!ecs.is_valid(self.world.id, currently_selected_entity) or !ecs.is_alive(self.world.id, currently_selected_entity))
                currently_selected_entity = self.scene_entity;
        }
        zgui.end();
    }

    pub fn draw_inspector(
        self: *Scene,
        asset_manager: *sf.AssetManager,
    ) !void {
        if (zgui.begin("Inspector", .{})) {
            const entity_name = ecs.get_name(self.world.id, currently_selected_entity) orelse {
                zgui.end();
                return;
            };
            const span_name = std.mem.span(entity_name);
            var buf = [_]u8{0} ** 128;
            std.mem.copyForwards(u8, &buf, span_name);
            if (zgui.inputText("Name: ", .{
                .buf = &buf,
                .flags = .{ .enter_returns_true = true, .read_only = currently_selected_entity == self.scene_entity },
            })) {
                _ = ecs.set_name(self.world.id, currently_selected_entity, @ptrCast(&buf));
            }
            if (currently_selected_entity != self.scene_entity) {
                zgui.dummy(.{ .h = 5, .w = 0 });
                zgui.text("Tags:", .{});
                tags.inspect_entity_tags(self.world.id, currently_selected_entity);
                zgui.dummy(.{ .h = 5, .w = 0 });
                try comps.inspect_entity_components(self.world.id, currently_selected_entity, asset_manager);
                if (zgui.button("Add Component", .{})) {
                    zgui.openPopup("Add Component Popup", .{});
                }
                if (zgui.beginPopup("Add Component Popup", .{})) {
                    if (zgui.selectable("Transform", .{ .flags = .{ .allow_double_click = true } })) {
                        ecs.add(self.world.id, currently_selected_entity, Transform);
                        _ = ecs.set(self.world.id, currently_selected_entity, Transform, .{});
                        zgui.closeCurrentPopup();
                    }
                    if (zgui.selectable("Mesh", .{ .flags = .{ .allow_double_click = true } })) {
                        { // Mesh
                            ecs.add(self.world.id, currently_selected_entity, Mesh);
                            if (self.asset.geometry_paths.items.len > 0) {
                                _ = ecs.set(self.world.id, currently_selected_entity, Mesh, self.mesh_manager.mesh_map.get(sf.AssetManager.generate_guid(self.asset.geometry_paths.items[0])).?);
                                _ = sf.MeshAsset.load_mesh(self.asset.geometry_paths.items[0], &asset_manager.mesh_manager, null, &self.vertices, &self.indices) catch |e| {
                                    log.err("Failed to add mesh component. {s}.", .{@typeName(@TypeOf(e))});
                                    zgui.closeCurrentPopup();
                                    return;
                                };
                            } else {
                                if (asset_manager.mesh_manager.mesh_map.count() > 0) {
                                    var iter = asset_manager.mesh_manager.mesh_map.iterator();
                                    const entry = iter.next().?;
                                    const path = asset_manager.mesh_manager.mesh_assets_map.get(entry.key_ptr.*).?.path;
                                    try self.asset.geometry_paths.append(path);
                                    try self.mesh_manager.mesh_map.put(entry.key_ptr.*, entry.value_ptr.*);
                                    _ = ecs.set(self.world.id, currently_selected_entity, Mesh, entry.value_ptr.*);
                                } else {
                                    var iter = asset_manager.mesh_manager.mesh_assets_map.iterator();
                                    const entry = iter.next().?;
                                    const path = entry.value_ptr.path;
                                    const mesh = sf.MeshAsset.load_mesh(path, &asset_manager.mesh_manager, null, &self.vertices, &self.indices) catch |e| {
                                        std.log.err("Failed to add mesh component. {s}.", .{@typeName(@TypeOf(e))});
                                        zgui.closeCurrentPopup();
                                        return;
                                    };
                                    try self.mesh_manager.mesh_assets_map.put(entry.key_ptr.*, entry.value_ptr.*);
                                    try self.mesh_manager.mesh_map.put(entry.key_ptr.*, mesh);
                                    try self.asset.geometry_paths.append(path);
                                    _ = ecs.set(self.world.id, currently_selected_entity, Mesh, mesh);
                                }
                            }
                            self.recreate_buffers();
                        }
                        { // Material
                            const gctx = sf.RendererState.renderer.?.gctx;
                            var guid: [64]u8 = undefined;
                            ecs.add(self.world.id, currently_selected_entity, Material);
                            if (self.material_manager.materials.count() > 0) {
                                var iter = self.material_manager.materials.iterator();
                                var entry = iter.next().?;
                                guid = entry.key_ptr.*;
                                _ = ecs.set(self.world.id, currently_selected_entity, Material, entry.value_ptr.*);
                            } else {
                                if (asset_manager.material_manager.materials.count() > 0) {
                                    var iter = asset_manager.material_manager.materials.iterator();
                                    while (iter.next()) |entry| {
                                        guid = entry.key_ptr.*;
                                        try self.material_manager.materials.put(entry.key_ptr.*, entry.value_ptr.*);
                                        _ = ecs.set(self.world.id, currently_selected_entity, Material, entry.value_ptr.*);
                                        try self.asset.material_paths.append(asset_manager.material_manager.material_asset_map.get(entry.key_ptr.*).?.path);
                                        break;
                                    }
                                } else {
                                    guid = sf.AssetManager.generate_guid("default");
                                    try self.material_manager.materials.put(guid, asset_manager.material_manager.default_material orelse val: {
                                        try sf.Material.create_default(&asset_manager.material_manager, &asset_manager.texture_manager, gctx);
                                        try sf.Material.create_default(&self.material_manager, &self.texture_manager, gctx);
                                        break :val asset_manager.material_manager.default_material.?;
                                    });
                                    try self.asset.material_paths.append("default");
                                    _ = ecs.set(self.world.id, currently_selected_entity, Material, asset_manager.material_manager.default_material.?);
                                }
                            }
                            const global_uniform_bgl = gctx.createBindGroupLayout(&.{
                                zgpu.bufferEntry(0, .{ .vertex = true, .fragment = true }, .uniform, true, 0),
                            });
                            defer gctx.releaseResource(global_uniform_bgl);
                            const local_bgl = gctx.createBindGroupLayout(
                                &.{
                                    zgpu.bufferEntry(0, .{ .vertex = true, .fragment = true }, .uniform, true, 0),
                                    zgpu.textureEntry(1, .{ .fragment = true }, .float, .tvdim_2d, false),
                                    zgpu.samplerEntry(2, .{ .fragment = true }, .filtering),
                                },
                            );
                            defer gctx.releaseResource(local_bgl);
                            const new_pipeline = self.pipeline_system.add_pipeline(gctx, &.{ global_uniform_bgl, local_bgl }, false) catch |e| {
                                std.log.err("Error when adding a new pipeline. {s}.", .{@typeName(@TypeOf(e))});
                                zgui.endPopup();
                                return;
                            };
                            self.pipeline_system.add_material(new_pipeline.*, guid) catch |e| {
                                std.log.err("Error when adding material to the newly created pipeline. {s}.", .{@typeName(@TypeOf(e))});
                                zgui.endPopup();
                                return;
                            };
                        }
                        zgui.closeCurrentPopup();
                    }
                    zgui.endPopup();
                }
            }
        }
        zgui.end();
    }

    fn draw_children_nodes(self: *Scene, entity: ecs.entity_t) void {
        var iter = ecs.children(self.world.id, entity);
        while (ecs.children_next(&iter)) {
            for (iter.entities()) |e| {
                var selected = false;
                if (e == currently_selected_entity) {
                    selected = true;
                }
                const name = ecs.get_name(self.world.id, e) orelse break;
                const casted_name: [:0]const u8 = std.mem.span(name);

                if (zgui.treeNodeFlags(casted_name, .{ .selected = selected, .open_on_arrow = true })) {
                    if (zgui.isItemClicked(.left)) {
                        currently_selected_entity = e;
                    }

                    if (zgui.beginPopupContextItem()) {
                        currently_selected_entity = e;
                        if (zgui.selectable("New", .{})) {
                            _ = self.world.entity_new_with_parent(e, "New Entity");
                            zgui.closeCurrentPopup();
                        }
                        if (zgui.selectable("Delete", .{})) {
                            self.world.entity_delete(e);
                            zgui.closeCurrentPopup();
                        }

                        zgui.endPopup();
                    }
                    draw_children_nodes(self, e);
                    zgui.treePop();
                }
            }
        }
    }

    pub fn serialize(self: *Scene, allocator: std.mem.Allocator, file_path: [:0]const u8) !void {
        var parse_arena = std.heap.ArenaAllocator.init(allocator);
        defer parse_arena.deinit();
        var file = try fs.cwd().createFile(file_path, .{});
        defer file.close();
        var writer = file.writer();
        var filter_desc = ecs.filter_desc_t{};
        filter_desc.terms[0] = .{ .id = ecs.Any };
        const filter = try ecs.filter_init(self.world.id, &filter_desc);
        var it = ecs.filter_iter(self.world.id, filter);
        var entity_list = std.ArrayList(ParseEntity).init(parse_arena.allocator());
        while (ecs.filter_next(&it)) {
            const world_id = it.world;
            const entities = it.entities();
            for (entities) |e| {
                var tag_list = std.ArrayList([:0]const u8).init(parse_arena.allocator());
                if (!self.world.entity_is_scene_entity(e)) continue;
                const _name = ecs.get_name(world_id, e).?;
                const entity_name = std.mem.span(_name);
                const path = self.world.entity_full_path(e, 0);
                // std.debug.print("\tTransform: {d}\n", .{transforms[i].matrix});
                var component_list = std.ArrayList(ParseComponent).init(parse_arena.allocator());
                {
                    const types = ecs.get_type(world_id, e).?;
                    var comp_len: usize = 0;
                    const type_count: usize = @intCast(types.count);
                    var components = types.array;
                    for (types.array[0..type_count]) |comp| {
                        if (ecs.id_is_pair(comp) or ecs.id_is_tag(world_id, comp)) {
                            continue;
                        }
                        components[comp_len] = comp;
                        comp_len += 1;
                    }
                    for (components, 0..comp_len) |comp, _| {
                        if (self.world.component_id_map.contains(comp)) {
                            const comp_name = self.world.component_id_map.get(comp).?;
                            if (std.mem.eql(u8, comp_name, "scene.components.Transform")) { // TODO: think of a better way of doing this
                                const transform = ecs.get(world_id, e, Transform).?;
                                try component_list.append(.{ .name = "scene.components.Transform", .value = .{ .matrix3 = .{
                                    transform.scale[0],
                                    transform.scale[1],
                                    transform.scale[1],
                                    transform.euler_angles[0],
                                    transform.euler_angles[1],
                                    transform.euler_angles[2],
                                    transform.position[0],
                                    transform.position[1],
                                    transform.position[2],
                                } } });
                            } else if (std.mem.eql(u8, comp_name, "scene.components.Mesh")) {
                                const mesh = ecs.get(world_id, e, Mesh).?;
                                try component_list.append(.{ .name = "scene.components.Mesh", .value = .{ .guid = mesh.guid } });
                            } else if (std.mem.eql(u8, comp_name, "renderer.material.Material")) {
                                const material = ecs.get(world_id, e, Material).?;
                                try component_list.append(.{ .name = "renderer.material.Material", .value = .{ .guid = material.guid } });
                            }
                        }
                    }
                }
                {
                    const types = ecs.get_type(world_id, e).?;
                    var tag_len: usize = 0;
                    const type_count: usize = @intCast(types.count);
                    var tags_arr = types.array;
                    for (types.array[0..type_count]) |comp| {
                        if (ecs.id_is_pair(comp)) {
                            continue;
                        }
                        if (ecs.id_is_tag(world_id, comp)) {
                            tags_arr[tag_len] = comp;
                            tag_len += 1;
                        }
                    }
                    for (tags_arr, 0..tag_len) |tag, _| {
                        if (self.world.tag_id_map.contains(tag)) {
                            const tag_name = self.world.tag_id_map.get(tag).?;
                            try tag_list.append(tag_name);
                        }
                    }
                }
                try entity_list.append(.{ .name = entity_name, .path = path, .id = e, .components = component_list.items, .tags = tag_list.items });
            }
        }
        var components = std.ArrayList([:0]const u8).init(parse_arena.allocator());
        var comp_iter = self.world.component_id_map.valueIterator();
        while (comp_iter.next()) |val| {
            try components.append(val.*);
        }
        var tags_arr = std.ArrayList([:0]const u8).init(parse_arena.allocator());
        var tags_iter = self.world.tag_id_map.valueIterator();
        while (tags_iter.next()) |val| {
            try tags_arr.append(val.*);
        }
        const world = ParseWorld{
            .entities = entity_list.items,
            .components = components.items,
            .tags = tags_arr.items,
        };
        var index: usize = 0;
        var found = false;
        for (self.asset.material_paths.items) |path| {
            if (std.mem.eql(u8, path, "default")) {
                found = true;
                break;
            }
            index += 1;
        }
        if (found) {
            _ = self.asset.material_paths.swapRemove(index);
        }
        try json.stringify(ParseScene{
            .world = world,
            .texture_paths = self.asset.texture_paths.items,
            .material_paths = self.asset.material_paths.items,
            .geometry_paths = self.asset.geometry_paths.items,
        }, .{}, writer);
    }
};

pub const World = struct {
    id: *ecs.world_t,
    component_id_map: std.AutoHashMap(ecs.id_t, [:0]const u8),
    tag_id_map: std.AutoHashMap(ecs.id_t, [:0]const u8),

    pub fn init(allocator: std.mem.Allocator) !World {
        const id = ecs.init();
        var component_id_map = std.AutoHashMap(ecs.id_t, [:0]const u8).init(allocator);
        try component_id_map.ensureTotalCapacity(256);
        var tag_id_map = std.AutoHashMap(ecs.id_t, [:0]const u8).init(allocator);
        try tag_id_map.ensureTotalCapacity(256);

        return World{
            .id = id,
            .component_id_map = component_id_map,
            .tag_id_map = tag_id_map,
        };
    }

    pub fn wrap(id: *ecs.world_t) World {
        return World{
            .id = id,
        };
    }

    pub fn deinit(self: *World) void {
        // self.tag_id_map.deinit();
        // self.component_id_map.deinit();
        // NOTE: this segfaults, so just leaving it here.
        _ = ecs.fini(self.id);
    }

    pub fn component_add(self: *World, comptime T: type) !void {
        ecs.COMPONENT(self.id, T);
        const id = ecs.id(T);
        try self.component_id_map.put(id, @typeName(T));
    }

    pub fn tag_add(self: *World, comptime T: type) !void {
        ecs.TAG(self.id, T);
        const id = ecs.id(T);
        try self.tag_id_map.put(id, @typeName(T));
    }

    pub fn entity_new(self: *World, name: [*:0]const u8) ecs.entity_t {
        var entity = ecs.new_entity(self.id, name);
        _ = ecs.set(self.id, entity, Transform, .{});
        return entity;
    }

    pub fn entity_new_with_parent(self: *World, parent: ecs.entity_t, name: [*:0]const u8) ecs.entity_t {
        var entity = ecs.new_w_id(self.id, ecs.pair(ecs.ChildOf, parent));
        _ = ecs.set(self.id, entity, Transform, .{});
        _ = ecs.set_name(self.id, entity, name);
        return entity;
    }

    pub fn entity_is_child_of(self: *World, target: ecs.entity_t, parent: ecs.entity_t) bool {
        var it = ecs.children(self.id, parent);
        while (ecs.children_next(&it)) {
            for (it.entities()) |e| {
                if (target == e) return true;
            }
        }
        return false;
    }

    pub fn entity_is_scene_entity(self: *World, entity: ecs.entity_t) bool {
        const path = self.entity_full_path(entity, 0);
        if (path.len < 6) return false;
        if (!std.mem.eql(u8, path[0..5], "Root.")) return false;
        return true;
    }

    pub fn entity_full_path(self: *const World, target: ecs.entity_t, from_parent: ecs.entity_t) [:0]const u8 {
        var name = name_stage: {
            const _name = ecs.get_name(self.id, target) orelse break :name_stage "";
            break :name_stage std.mem.span(_name);
        };
        const path = ecs.get_path_w_sep(self.id, from_parent, target, ".", null).?;
        const len = val: {
            var separator_index: u32 = 0;
            while (true) {
                if (path[separator_index] != '.' and separator_index == name.len) break :val separator_index;
                separator_index += 1;
                if (path[separator_index] == '.' and path[separator_index + 1] == name[0]) {
                    separator_index += 1;
                    var inner_index: u32 = 0;
                    while (path[separator_index] == name[inner_index]) {
                        inner_index += 1;
                        separator_index += 1;
                        if (inner_index == name.len) break :val separator_index;
                    }
                }
            }
            break :val separator_index;
        };
        const casted: [:0]const u8 = @ptrCast(path[0..len]);
        return casted;
    }

    pub fn entity_delete(self: *World, target: ecs.entity_t) void {
        var iter = ecs.children(self.id, target);
        while (ecs.children_next(&iter)) {
            for (iter.entities()) |e| {
                entity_delete(self, e);
            }
        }
        ecs.delete(self.id, target);
    }

    pub fn entity_get_parent(self: *const World, target: ecs.entity_t) ecs.entity_t {
        return ecs.get_target(self.id, target, ecs.ChildOf, 0);
    }

    pub fn entity_get_parent_world_id(world: *const ecs.world_t, target: ecs.entity_t) ecs.entity_t {
        return ecs.get_target(world, target, ecs.ChildOf, 0);
    }

    pub fn deserialize(
        self: *World,
        scene_asset: *const SceneAsset,
        gctx: *zgpu.GraphicsContext,
        global_uniform_bgl: zgpu.BindGroupLayoutHandle,
        pipeline_system: *sf.PipelineSystem,
        texture_manager: *sf.TextureManager,
        material_manager: *sf.MaterialManager,
        mesh_manager: *sf.MeshManager,
        meshes: *std.ArrayList(Mesh),
        vertices: *std.ArrayList(sf.Vertex),
        indices: *std.ArrayList(u32),
    ) !ecs.entity_t {
        for (scene_asset.texture_paths.items) |texture_path| {
            try sf.TextureManager.add_texture(texture_manager, texture_path, gctx, .{ .texture_binding = true, .copy_dst = true });
        }
        const local_bgl = gctx.createBindGroupLayout(
            &.{
                zgpu.bufferEntry(0, .{ .vertex = true, .fragment = true }, .uniform, true, 0),
                zgpu.textureEntry(1, .{ .fragment = true }, .float, .tvdim_2d, false),
                zgpu.samplerEntry(2, .{ .fragment = true }, .filtering),
            },
        );
        defer gctx.releaseResource(local_bgl);
        var pipeline = try pipeline_system.add_pipeline(gctx, &.{ global_uniform_bgl, local_bgl }, false);
        { // default material & pipeline
            try sf.Material.create_default(material_manager, texture_manager, gctx);
            var default_pipeline = try pipeline_system.add_pipeline(gctx, &.{ global_uniform_bgl, local_bgl }, false);
            try pipeline_system.add_material(default_pipeline.*, sf.AssetManager.generate_guid("default"));
        }
        // TODO: a module that parses material files (json or smth) and outputs bind group layouts to pass to pipeline system
        for (scene_asset.material_paths.items) |material_path| {
            const material_asset = material_manager.material_asset_map.get(sf.AssetManager.generate_guid(material_path)).?;
            // TODO: look into making multiple textures per material
            try sf.MaterialManager.add_material(material_manager, material_path, gctx, texture_manager, &.{
                zgpu.bufferEntry(0, .{ .vertex = true, .fragment = true }, .uniform, true, 0),
                zgpu.textureEntry(1, .{ .fragment = true }, .float, .tvdim_2d, false),
                zgpu.samplerEntry(2, .{ .fragment = true }, .filtering),
            }, @sizeOf(sf.Uniforms), material_asset.texture_guid.?);
            try pipeline_system.add_material(pipeline.*, sf.AssetManager.generate_guid(material_path));
        }
        for (scene_asset.geometry_paths.items) |geometry_path| {
            _ = try sf.MeshAsset.load_mesh(geometry_path, mesh_manager, meshes, vertices, indices);
        }
        // add these by default
        try self.component_add(Transform);
        try self.component_add(Mesh);
        try self.component_add(Material);
        const scene_entity = self.entity_new("Root");
        var entities_added: u32 = 0;
        if (scene_asset.world) |parser_world| {
            for (parser_world.components) |comp| {
                const comp_type = comps.name_type_map.get(comp).?;
                switch (comp_type) {
                    .transform => {},
                    .mesh => {},
                    .material => {},
                }
            }
            for (parser_world.tags) |tag| {
                const tag_type = tags.name_type_map.get(tag).?;
                switch (tag_type) {
                    .test_tag => {
                        try self.tag_add(TestTag);
                    },
                }
            }
            for (parser_world.entities) |e| {
                const entity = ecs.new_from_path_w_sep(self.id, 0, e.path, ".", null);
                for (e.tags) |tag| {
                    const tag_type = tags.name_type_map.get(tag).?;
                    switch (tag_type) {
                        .test_tag => {
                            const id = ecs.id(TestTag);
                            _ = ecs.add_id(self.id, entity, id);
                        },
                    }
                }
                entities_added += 1;
                for (e.components) |comp| {
                    const comp_type = comps.name_type_map.get(comp.name).?;
                    switch (comp_type) {
                        .transform => {
                            var transform: Transform = .{
                                .position = .{ comp.value.matrix3[6], comp.value.matrix3[7], comp.value.matrix3[8], 0 },
                                .euler_angles = .{ comp.value.matrix3[3], comp.value.matrix3[4], comp.value.matrix3[5] },
                                .scale = .{ comp.value.matrix3[0], comp.value.matrix3[1], comp.value.matrix3[2], 0 },
                                .rot_dirty = true,
                            };
                            transform.calculate_local();
                            _ = ecs.set(self.id, entity, Transform, transform);
                        },
                        .mesh => {
                            const mesh = try mesh_manager.get_mesh(comp.value.guid);
                            _ = ecs.set(self.id, entity, Mesh, mesh);
                        },
                        .material => {
                            _ = ecs.set(self.id, entity, Material, material_manager.materials.get(comp.value.guid) orelse material_manager.default_material.?);
                        },
                    }
                }
            }
        }
        if (entities_added == 0)
            _ = self.entity_new_with_parent(scene_entity, "New Entity");
        return scene_entity;
    }
};

pub const SceneManager = struct {
    arena_allocator: std.heap.ArenaAllocator,
    asset_map: std.AutoHashMap([64]u8, SceneAsset),

    pub fn init(allocator: std.mem.Allocator, config_path: []const u8) !SceneManager {
        var arena = std.heap.ArenaAllocator.init(allocator);
        var arena_alloc = arena.allocator();
        var parse_arena = std.heap.ArenaAllocator.init(allocator);
        defer parse_arena.deinit();
        const config_data = std.fs.cwd().readFileAlloc(parse_arena.allocator(), config_path, 512 * 16) catch |e| {
            log.err("Failed to parse texture config file. Given path:{s}", .{config_path});
            return e;
        };
        const Config = struct {
            database: [][:0]const u8,
        };
        const config = try json.parseFromSliceLeaky(Config, arena.allocator(), config_data, .{});
        var asset_map = std.AutoHashMap([64]u8, SceneAsset).init(arena_alloc);
        try asset_map.ensureTotalCapacity(@intCast(config.database.len));
        for (config.database) |path| {
            const scene_asset = try SceneAsset.create(arena.allocator(), parse_arena.allocator(), path);
            try asset_map.putNoClobber(scene_asset.guid, scene_asset);
        }
        return SceneManager{
            .arena_allocator = arena,
            .asset_map = asset_map,
        };
    }

    pub fn deinit(self: *SceneManager) void {
        self.arena_allocator.deinit();
    }
};
