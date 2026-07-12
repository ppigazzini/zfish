// Pending-state registry (ANNEX B.6): the keyed store of per-slot PendingStateStorage
// handed from the UCI thread to the search pool. Owns its state (the entries list)
// and lifecycle; the engine facade calls its pub API. state_list/graph_layout only.

const std = @import("std");
const state_list = @import("state_list");
const graph_layout = @import("graph_layout");
const runtime_hooks = @import("runtime_hooks");

pub const PendingStateStorage = state_list.PendingStateStorage;

const PendingStateEntry = struct {
    slot_key: usize,
    storage: *PendingStateStorage,
};

var pending_state_entries = std.ArrayListUnmanaged(PendingStateEntry).empty;

pub fn ensurePendingStateStorage(states_slot: *anyopaque) ?*PendingStateStorage {
    const slot_key = @intFromPtr(states_slot);

    if (findPendingStateIndex(slot_key)) |index| {
        return pending_state_entries.items[index].storage;
    }

    // Null on OOM (was `@panic("OOM")`); setPosition reports it as a UCI error
    // message through its existing `?[*:0]u8` channel instead of crashing.
    const state_storage = state_list.storageCreate() orelse return null;
    pending_state_entries.append(std.heap.c_allocator, .{
        .slot_key = slot_key,
        .storage = state_storage,
    }) catch {
        state_list.storageDestroy(state_storage);
        return null;
    };

    return state_storage;
}

fn lookupPendingStateStorage(slot_key: usize) ?*PendingStateStorage {
    if (findPendingStateIndex(slot_key)) |index| {
        return pending_state_entries.items[index].storage;
    }

    return null;
}

fn removePendingStateStorage(slot_key: usize) ?*PendingStateStorage {
    if (findPendingStateIndex(slot_key)) |index| {
        const state_storage = pending_state_entries.items[index].storage;
        _ = pending_state_entries.swapRemove(index);
        return state_storage;
    }

    return null;
}

fn findPendingStateIndex(slot_key: usize) ?usize {
    var index: usize = 0;
    while (index < pending_state_entries.items.len) : (index += 1) {
        if (pending_state_entries.items[index].slot_key == slot_key) {
            return index;
        }
    }

    return null;
}

pub fn pendingStatesAvailable(states_slot: *anyopaque) u8 {
    const state_storage = lookupPendingStateStorage(@intFromPtr(states_slot)) orelse return 0;
    return @intFromBool(state_list.storageHasStates(state_storage));
}

pub fn handoffPendingStates(pool: *graph_layout.ThreadPool, states_slot: *anyopaque) u8 {
    const state_storage = lookupPendingStateStorage(@intFromPtr(states_slot)) orelse return 0;
    if (!state_list.storageHasStates(state_storage))
        return 0;

    runtime_hooks.setup_states_adopt_from_storage(pool, state_storage);
    return @intFromBool(pool.hasSetupStates());
}

pub fn releasePendingStateSlot(states_slot: *anyopaque) void {
    if (removePendingStateStorage(@intFromPtr(states_slot))) |state_storage| {
        state_list.storageDestroy(state_storage);
    }
}
