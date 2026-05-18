const psq_feature: u8 = 0;
const threat_feature: u8 = 1;
const white: u8 = 0;
const black: u8 = 1;

extern fn zfish_accumulator_stack_size(stack: *const anyopaque) usize;
extern fn zfish_accumulator_state_computed(
    stack: *const anyopaque,
    feature_kind: u8,
    index: usize,
    perspective: u8,
) bool;
extern fn zfish_accumulator_requires_refresh(
    stack: *const anyopaque,
    feature_kind: u8,
    index: usize,
    perspective: u8,
) bool;
extern fn zfish_accumulator_forward_update(
    stack: *anyopaque,
    feature_kind: u8,
    perspective: u8,
    pos: *const anyopaque,
    feature_transformer: *const anyopaque,
    begin: usize,
) void;
extern fn zfish_accumulator_backward_update(
    stack: *anyopaque,
    feature_kind: u8,
    perspective: u8,
    pos: *const anyopaque,
    feature_transformer: *const anyopaque,
    end: usize,
) void;
extern fn zfish_accumulator_refresh_latest(
    stack: *anyopaque,
    feature_kind: u8,
    perspective: u8,
    pos: *const anyopaque,
    feature_transformer: *const anyopaque,
    cache: *anyopaque,
) void;

pub fn evaluate(
    stack: *anyopaque,
    pos: *const anyopaque,
    feature_transformer: *const anyopaque,
    cache: *anyopaque,
) void {
    evaluateSide(psq_feature, white, stack, pos, feature_transformer, cache);
    evaluateSide(psq_feature, black, stack, pos, feature_transformer, cache);
    evaluateSide(threat_feature, white, stack, pos, feature_transformer, cache);
    evaluateSide(threat_feature, black, stack, pos, feature_transformer, cache);
}

fn evaluateSide(
    feature_kind: u8,
    perspective: u8,
    stack: *anyopaque,
    pos: *const anyopaque,
    feature_transformer: *const anyopaque,
    cache: *anyopaque,
) void {
    const last_usable = findLastUsable(feature_kind, stack, perspective);

    if (zfish_accumulator_state_computed(stack, feature_kind, last_usable, perspective)) {
        zfish_accumulator_forward_update(
            stack,
            feature_kind,
            perspective,
            pos,
            feature_transformer,
            last_usable,
        );
    } else {
        zfish_accumulator_refresh_latest(
            stack,
            feature_kind,
            perspective,
            pos,
            feature_transformer,
            cache,
        );
        zfish_accumulator_backward_update(
            stack,
            feature_kind,
            perspective,
            pos,
            feature_transformer,
            last_usable,
        );
    }
}

fn findLastUsable(feature_kind: u8, stack: *const anyopaque, perspective: u8) usize {
    const size = zfish_accumulator_stack_size(stack);
    var current = size - 1;

    while (current > 0) : (current -= 1) {
        if (zfish_accumulator_state_computed(stack, feature_kind, current, perspective))
            return current;

        if (zfish_accumulator_requires_refresh(stack, feature_kind, current, perspective))
            return current;
    }

    return 0;
}
