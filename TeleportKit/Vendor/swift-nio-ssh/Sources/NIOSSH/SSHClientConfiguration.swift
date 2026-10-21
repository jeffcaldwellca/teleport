//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2020 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

/// Configuration for an SSH client.
public struct SSHClientConfiguration {
    /// The user authentication delegate to be used with this client.
    public var userAuthDelegate: NIOSSHClientUserAuthenticationDelegate

    /// The server authentication delegate to be used with this client.
    public var serverAuthDelegate: NIOSSHClientServerAuthenticationDelegate

    /// The global request delegate to be used with this client.
    public var globalRequestDelegate: GlobalRequestDelegate

    /// The enabled TransportProtectionSchemes
    public var transportProtectionSchemes: [NIOSSHTransportProtection.Type] = SSHConnectionStateMachine.bundledTransportProtectionSchemes

    /// The enabled KeyExchangeAlgorithms
    public var keyExchangeAlgorithms: [NIOSSHKeyExchangeAlgorithmProtocol.Type] = SSHKeyExchangeStateMachine.bundledKeyExchangeImplementations

    /// The maximum packet size that this NIOSSH client will accept
    public var maximumPacketSize = SSHPacketParser.defaultMaximumPacketSize
    
    /// The trusted certificate authority public keys for host authentication.
    /// When set, hosts presenting certificates signed by these CAs will be authenticated
    /// if the certificate is valid and the principal matches the hostname.
    public var trustedHostCAKeys: [NIOSSHPublicKey] = []
    
    /// The hostname that this client is connecting to.
    /// This is used for validating host certificates when `trustedHostCAKeys` is configured.
    /// If not set, host certificate validation will accept any hostname.
    public var hostname: String?

    public init(userAuthDelegate: NIOSSHClientUserAuthenticationDelegate,
                serverAuthDelegate: NIOSSHClientServerAuthenticationDelegate,
                globalRequestDelegate: GlobalRequestDelegate? = nil)
    {
        self.userAuthDelegate = userAuthDelegate
        self.serverAuthDelegate = serverAuthDelegate
        self.globalRequestDelegate = globalRequestDelegate ?? DefaultGlobalRequestDelegate()
    }
}
