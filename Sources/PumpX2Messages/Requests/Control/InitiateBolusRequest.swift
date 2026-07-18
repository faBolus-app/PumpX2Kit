import Foundation

/// The final command that initiates a bolus. Must follow a `BolusPermissionRequest` and use
/// the `bolusID` from its response. Signed + modifies insulin delivery — the most
/// safety-critical outgoing message. Port of `request/control/InitiateBolusRequest`
/// (opcode 0x9E / -98, size 37 + 24-byte HMAC).
///
/// Volumes are in **milliunits** (1000 = 1.0 u).
public struct InitiateBolusRequest: Message {
    public static let minBolusMilliunits: UInt32 = 50        // 0.05 u
    public static let minExtendedBolusMilliunits: UInt32 = 400 // 0.40 u

    public static let props = MessageProps(
        opCode: 0x9E,               // -98 as unsigned
        size: 37,
        signed: true,
        type: .request,
        characteristic: .control,
        modifiesInsulinDelivery: true,
        responseOpCode: 0x9F        // InitiateBolusResponse
    )

    public var cargo: [UInt8]

    public private(set) var totalVolume: UInt32 = 0
    public private(set) var bolusID: Int = 0
    public private(set) var bolusTypeBitmask: Int = 0
    public private(set) var foodVolume: UInt32 = 0
    public private(set) var correctionVolume: UInt32 = 0
    public private(set) var bolusCarbs: Int = 0
    public private(set) var bolusBG: Int = 0
    public private(set) var bolusIOB: UInt32 = 0
    public private(set) var extendedVolume: UInt32 = 0
    public private(set) var extendedSeconds: UInt32 = 0
    public private(set) var extended3: UInt32 = 0

    public init() { self.cargo = [] }

    /// Standard (non-extended) bolus.
    public init(
        totalVolume: UInt32,
        bolusID: Int,
        bolusTypeBitmask: Int,
        foodVolume: UInt32 = 0,
        correctionVolume: UInt32 = 0,
        bolusCarbs: Int = 0,
        bolusBG: Int = 0,
        bolusIOB: UInt32 = 0
    ) {
        self.init(
            totalVolume: totalVolume, bolusID: bolusID, bolusTypeBitmask: bolusTypeBitmask,
            foodVolume: foodVolume, correctionVolume: correctionVolume, bolusCarbs: bolusCarbs,
            bolusBG: bolusBG, bolusIOB: bolusIOB, extendedVolume: 0, extendedSeconds: 0, extended3: 0
        )
    }

    /// Full form, including extended-bolus fields.
    public init(
        totalVolume: UInt32,
        bolusID: Int,
        bolusTypeBitmask: Int,
        foodVolume: UInt32,
        correctionVolume: UInt32,
        bolusCarbs: Int,
        bolusBG: Int,
        bolusIOB: UInt32,
        extendedVolume: UInt32,
        extendedSeconds: UInt32,
        extended3: UInt32
    ) {
        precondition(totalVolume >= Self.minBolusMilliunits
            || (totalVolume + extendedVolume) >= Self.minExtendedBolusMilliunits)
        precondition(bolusID > 0)
        self.cargo = Self.buildCargo(
            totalVolume: totalVolume, bolusID: bolusID, bolusTypeId: bolusTypeBitmask,
            foodVolume: foodVolume, correctionVolume: correctionVolume, bolusCarbs: bolusCarbs,
            bolusBG: bolusBG, bolusIOB: bolusIOB, extendedVolume: extendedVolume,
            extendedSeconds: extendedSeconds, extended3: extended3)
        self.totalVolume = totalVolume
        self.bolusID = bolusID
        self.bolusTypeBitmask = bolusTypeBitmask
        self.foodVolume = foodVolume
        self.correctionVolume = correctionVolume
        self.bolusCarbs = bolusCarbs
        self.bolusBG = bolusBG
        self.bolusIOB = bolusIOB
        self.extendedVolume = extendedVolume
        self.extendedSeconds = extendedSeconds
        self.extended3 = extended3
    }

    public mutating func parse(_ raw: [UInt8]) {
        let raw = removeSignedRequestHmacBytes(raw)
        precondition(raw.count == Self.props.size)
        self.cargo = raw
        self.totalVolume = Bytes.readUint32(raw, 0)
        self.bolusID = Bytes.readShort(raw, 4)
        self.bolusTypeBitmask = Int(raw[8])
        self.foodVolume = Bytes.readUint32(raw, 9)
        self.correctionVolume = Bytes.readUint32(raw, 13)
        self.bolusCarbs = Bytes.readShort(raw, 17)
        self.bolusBG = Bytes.readShort(raw, 19)
        self.bolusIOB = Bytes.readUint32(raw, 21)
        self.extendedVolume = Bytes.readUint32(raw, 25)
        self.extendedSeconds = Bytes.readUint32(raw, 29)
        self.extended3 = Bytes.readUint32(raw, 33)
    }

    public static func buildCargo(
        totalVolume: UInt32, bolusID: Int, bolusTypeId: Int, foodVolume: UInt32,
        correctionVolume: UInt32, bolusCarbs: Int, bolusBG: Int, bolusIOB: UInt32,
        extendedVolume: UInt32, extendedSeconds: UInt32, extended3: UInt32
    ) -> [UInt8] {
        Bytes.combine(
            Bytes.toUint32(totalVolume),
            Bytes.firstTwoBytesLittleEndian(bolusID),
            [0, 0],
            [UInt8(truncatingIfNeeded: bolusTypeId)],
            Bytes.toUint32(foodVolume),
            Bytes.toUint32(correctionVolume),
            Bytes.firstTwoBytesLittleEndian(bolusCarbs),
            Bytes.firstTwoBytesLittleEndian(bolusBG),
            Bytes.toUint32(bolusIOB),
            Bytes.toUint32(extendedVolume),
            Bytes.toUint32(extendedSeconds),
            Bytes.toUint32(extended3)
        )
    }
}
