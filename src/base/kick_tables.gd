class_name KickTables

const NonIWallKickData: = {
    Vector2(0, 1): [Vector2(0, 0), Vector2(-1, 0), Vector2(-1, -1), Vector2(0, 2), Vector2(-1, 2)],
    Vector2(0, 2): [Vector2(0, 0), Vector2(0, -1), Vector2(1, -1), Vector2(-1, -1), Vector2(1, 0), Vector2(-1, 0)],
    Vector2(0, 3): [Vector2(0, 0), Vector2(1, 0), Vector2(1, -1), Vector2(0, 2), Vector2(1, 2)],
    Vector2(1, 0): [Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, -2), Vector2(1, -2)],
    Vector2(1, 2): [Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, -2), Vector2(1, -2)],
    Vector2(1, 3): [Vector2(0, 0), Vector2(1, 0), Vector2(1, -2), Vector2(1, 1), Vector2(0, -2), Vector2(0, -1)],
    Vector2(2, 0): [Vector2(0, 0), Vector2(0, 1), Vector2(-1, 1), Vector2(1, 1), Vector2(-1, 0), Vector2(1, 0)],
    Vector2(2, 1): [Vector2(0, 0), Vector2(-1, 0), Vector2(-1, -1), Vector2(0, 2), Vector2(-1, 2)],
    Vector2(2, 3): [Vector2(0, 0), Vector2(1, 0), Vector2(1, -1), Vector2(0, 2), Vector2(1, 2)],
    Vector2(3, 0): [Vector2(0, 0), Vector2(-1, 0), Vector2(-1, 1), Vector2(0, -2), Vector2(-1, -2)],
    Vector2(3, 1): [Vector2(0, 0), Vector2(-1, 0), Vector2(-1, -2), Vector2(-1, -1), Vector2(0, -2), Vector2(0, -1)],
    Vector2(3, 2): [Vector2(0, 0), Vector2(-1, 0), Vector2(-1, 1), Vector2(0, -2), Vector2(-1, -2)]
}

const IWallKickData = {
    # 180s use the same SRS+ kicks as the other pieces; without these the I could not 180 at all
    Vector2(0, 2): [Vector2(0, 0), Vector2(0, -1), Vector2(1, -1), Vector2(-1, -1), Vector2(1, 0), Vector2(-1, 0)],
    Vector2(2, 0): [Vector2(0, 0), Vector2(0, 1), Vector2(-1, 1), Vector2(1, 1), Vector2(-1, 0), Vector2(1, 0)],
    Vector2(1, 3): [Vector2(0, 0), Vector2(1, 0), Vector2(1, -2), Vector2(1, 1), Vector2(0, -2), Vector2(0, -1)],
    Vector2(3, 1): [Vector2(0, 0), Vector2(-1, 0), Vector2(-1, -2), Vector2(-1, -1), Vector2(0, -2), Vector2(0, -1)],
    Vector2(0, 1): [Vector2(0, 0), Vector2(-2, 0), Vector2(1, 0), Vector2(-2, 1), Vector2(1, -2)],
    Vector2(0, 3): [Vector2(0, 0), Vector2(-1, 0), Vector2(2, 0), Vector2(-1, -2), Vector2(2, 1)],
    Vector2(1, 0): [Vector2(0, 0), Vector2(2, 0), Vector2(-1, 0), Vector2(2, -1), Vector2(-1, 2)],
    Vector2(1, 2): [Vector2(0, 0), Vector2(-1, 0), Vector2(2, 0), Vector2(-1, -2), Vector2(2, 1)],
    Vector2(2, 1): [Vector2(0, 0), Vector2(1, 0), Vector2(-2, 0), Vector2(1, 2), Vector2(-2, -1)],
    Vector2(2, 3): [Vector2(0, 0), Vector2(2, 0), Vector2(-1, 0), Vector2(2, -1), Vector2(-1, 2)],
    Vector2(3, 0): [Vector2(0, 0), Vector2(1, 0), Vector2(-2, 0), Vector2(1, 2), Vector2(-2, -1)],
    Vector2(3, 2): [Vector2(0, 0), Vector2(-2, 0), Vector2(1, 0), Vector2(-2, 1), Vector2(1, -2)]
}