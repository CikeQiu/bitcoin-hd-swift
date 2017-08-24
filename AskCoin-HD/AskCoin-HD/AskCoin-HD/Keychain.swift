//
//  ASKKeychain.swift
//  AskCoin-HD
//
//  Created by 仇弘扬 on 2017/8/14.
//  Copyright © 2017年 askcoin. All rights reserved.
//

import UIKit
import CryptoSwift
import ASKSecp256k1

let BTCKeychainMainnetPrivateVersion: UInt32 = 0x0488ADE4
let BTCKeychainMainnetPublicVersion: UInt32 = 0x0488B21E

let BTCKeychainTestnetPrivateVersion: UInt32 = 0x04358394
let BTCKeychainTestnetPublicVersion: UInt32 = 0x043587CF

let BTCMasterKeychainPath = "m"
let BTCKeychainHardenedSymbol = "'"
let BTCKeychainPathSeparator = "/"

class Keychain: NSObject {
	
	enum KeyDerivationError: Error {
		case indexInvalid
		case pathInvalid
		case privateKeyNil
		case publicKeyNil
		case chainCodeNil
		case notMasterKey
	}
	
	private var privateKey: Data?
//	private var publicKey: Data?
	private var chainCode: Data?
	
	fileprivate var isMasterKey = false
	
	var network = Network()
	var depth: UInt8 = 0
	var hardened = false
	var index: UInt32 = 0
	
	override init() {
		
	}
	
	convenience init(seedString: String) throws {
		let seed = seedString.ck_mnemonicData()
		let seedBytes = seed.bytes
		do {
			let hmac = try HMAC(key: "Bitcoin seed", variant: .sha512).authenticate(seedBytes)
			self.init(hmac: hmac)
			isMasterKey = true
		} catch {
			throw error
		}
	}
	
	private init(hmac: Array<UInt8>) {
		privateKey = Data(hmac[0..<32])
		chainCode = Data(hmac[32..<64])
	}
	
	lazy var identifier: Data? = {
		if let pubKey = self.publicKey {
			return pubKey.BTCHash160()
		}
		return nil
	}()
	
	var parentFingerprint: UInt32 = 0
	
	lazy var fingerprint: UInt32 = {
		if let id = self.identifier {
			return UInt32(bytes: id.bytes[0..<4])
		}
		return 0
	}()
	
	private lazy var publicKey: Data? = {
		guard let prvKey = self.privateKey else {
			return nil
		}
		return CKSecp256k1.generatePublicKey(withPrivateKey: prvKey, compression: true)
	}()
	
	// MARK: - Extended private key
	lazy var extendedPrivateKey: String = {
		self.extendedPrivateKeyData.base58Check()
	}()
	
	lazy var extendedPrivateKeyData: Data = {
		guard self.privateKey != nil else {
			return Data()
		}
		
		var toReturn = Data()
		
		let version = self.network.isMainNet ? BTCKeychainMainnetPrivateVersion : BTCKeychainTestnetPrivateVersion
		toReturn += self.extendedKeyPrefix(with: version)
		
		toReturn += UInt8(0).hexToData()
		
		if let prikey = self.privateKey {
			toReturn += prikey
		}
		
		return toReturn
	}()
	
	// MARK: - Extended public key
	lazy var extendedPublicKey: String = {
		self.extendedPublicKeyData.base58Check()
	}()
	
	lazy var extendedPublicKeyData: Data = {
		guard self.publicKey != nil else {
			return Data()
		}
		
		var toReturn = Data()
		
		let version = self.network.isMainNet ? BTCKeychainMainnetPublicVersion : BTCKeychainTestnetPublicVersion
		toReturn += self.extendedKeyPrefix(with: version)
		
		if let pubkey = self.publicKey {
			toReturn += pubkey
		}
		
		return toReturn
	}()
	
	func extendedKeyPrefix(with version: UInt32) -> Data {
		var toReturn = Data()
		
		let versionData = version.hexToData()
		toReturn += versionData
		
		let depthData = depth.hexToData()
		toReturn += depthData
		
		let parentFPData = parentFingerprint.hexToData()
		toReturn += parentFPData
		
		let childIndex = hardened ? (0x80000000 | index) : index
		let childIndexData = childIndex.hexToData()
		toReturn += childIndexData
		
		if let cCode = chainCode {
			toReturn += cCode
		}
		else
		{
			print(KeyDerivationError.chainCodeNil)
		}
		
		return toReturn
	}
	
	func derivedKeychain(at path: String) throws -> Keychain {
		
		if path == BTCMasterKeychainPath || path == BTCKeychainPathSeparator || path == "" {
			return self
		}
		
		var paths = path.components(separatedBy: BTCKeychainPathSeparator)
		if path.hasPrefix(BTCMasterKeychainPath) {
			paths.removeFirst()
		}
		
		var kc = self
		
		for indexString in paths {
			var isHardened = false
			var temp = indexString
			if indexString.hasSuffix(BTCKeychainHardenedSymbol) {
				isHardened = true
				temp = temp.substring(to: temp.index(temp.endIndex, offsetBy: -1))
			}
			if let index = UInt32(temp) {
				kc = try kc.derivedKeychain(at: index, hardened: isHardened)
				continue
			}
			throw KeyDerivationError.pathInvalid
		}
		
		return kc
	}
	
	func derivedKeychain(at index: UInt32, hardened: Bool = true) throws -> Keychain {
		
		let edge: UInt32 = 0x80000000
		
		guard (edge & UInt32(index)) == 0 else {
			throw KeyDerivationError.indexInvalid
		}
		
		guard let prvKey = privateKey else {
			throw KeyDerivationError.privateKeyNil
		}
		
		guard let pubKey = publicKey else {
			throw KeyDerivationError.publicKeyNil
		}
		
		guard let chCode = chainCode else {
			throw KeyDerivationError.chainCodeNil
		}
		
		var data = Data()
		
		if hardened {
			let padding: UInt8 = 0
			data += padding.hexToData()
			data += prvKey
		}
		else
		{
			data += pubKey
		}
		
		let indexBE = hardened ? (edge + index) : index
		data += indexBE.hexToData()
		
		let digestArray = try HMAC(key: chCode.bytes, variant: .sha512).authenticate(data.bytes)
		
		let factor = BInt(data: Data(digestArray[0..<32]))
		let curveOrder = BInt(hex: "FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141")
		
		let derivedKeychain = Keychain(hmac: digestArray)
		
		let pkNum = BInt(data: Data(prvKey))
		
		let pkData = ((pkNum + factor) % curveOrder).data
		
		derivedKeychain.privateKey = pkData
		derivedKeychain.depth = depth + 1
		derivedKeychain.parentFingerprint = fingerprint
		derivedKeychain.index = index
		derivedKeychain.hardened = hardened
		
		return derivedKeychain
	}
	
}

// MARK: - BIP44
extension Keychain {
	
	func checkMasterKey() throws {
		guard isMasterKey else {
			throw KeyDerivationError.notMasterKey
		}
	}
	
	func bitcoinMainnetKeychain() throws -> Keychain {
		try checkMasterKey()
		return try derivedKeychain(at: "44'/0'")
	}
	func bitcoinTestnetKeychain() throws -> Keychain {
		try checkMasterKey()
		return try derivedKeychain(at: "44'/1'")
	}
}

