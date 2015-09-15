//
//  LocalPeer.swift
//  Pods
//
//  Created by Julian Asamer on 04/07/14.
//
//

import Foundation

/** Used to notify about discovered peers. */
public typealias PeerDiscoveredClosure = (peer: RemotePeer) -> ()
/** Used to notify about removed peers. */
public typealias PeerRemovedClosure = (peer: RemotePeer) -> ()
/** Used to notify about incoming connections peers. */
public typealias ConnectionClosure = (peer: RemotePeer, connection: Connection) -> ()

/**
* A LocalPeer advertises the local peer in the network and browses for other peers.
*
* It requires one or more Modules to accomplish this. Two Modules that come with Reto are the WlanModule and the RemoteP2P module.
*
* The LocalPeer can also be used to establish multicast connections to multiple other peers.
*/
@objc(RTLocalPeer) public class LocalPeer: NSObject, ConnectionManager, RouterHandler {
    /** This peer's unique identifier. If not specified in the constructor, it has a random value. */
    public let identifier: UUID
    /** The dispatch queue used to execute all networking operations and callbacks */
    public let dispatchQueue: dispatch_queue_t
    /** The set of peers currently reachable */
    public var peers: Set<RemotePeer> { get { return Set(knownPeers.values) } }

    /**
    * Constructs a new LocalPeer object. A random identifier will be used for the LocalPeer.
    * Note that a LocalPeer is not functional without modules. You can add modules later with the addModule method.
    * The main dispatch queue is used for all networking code.
    */
    public override convenience init() {
        self.init(identifier: UUID.random(), modules: [], dispatchQueue: dispatch_get_main_queue())
    }
    
    /**
    * Constructs a new LocalPeer object. A random identifier will be used for the LocalPeer.
    * Note that a LocalPeer is not functional without modules. You can add modules later with the addModule method.
    *
    * @param dispatchQueue The dispatchQueue used to run all networking code with. The dispatchQueue can be used to specifiy the thread that should be used.
    */
    public convenience init(dispatchQueue: dispatch_queue_t) {
        self.init(identifier: UUID.random(), modules: [], dispatchQueue: dispatchQueue)
    }
    /**
    * Constructs a new LocalPeer object.
    *
    * @param modules An array of modules used for the underlying networking functionality. For example: @see WlanModule, @see RemoteP2PModule.
    * @param dispatchQueue The dispatchQueue used to run all networking code with. The dispatchQueue can be used to specifiy the thread that should be used.
    */
    public convenience init(modules: [Module], dispatchQueue: dispatch_queue_t) {
        self.init(identifier: UUID.random(), modules: modules, dispatchQueue: dispatchQueue)
    }
    /**
    * Constructs a new LocalPeer object. A random identifier will be used for the LocalPeer.
    *
    * @param localPeerIdentifier The identifier used for the peer
    * @param modules An array of modules used for the underlying networking functionality. For example: @see WlanModule, @see RemoteP2PModule.
    * @param dispatchQueue The dispatchQueue used to run all networking code with. The dispatchQueue can be used to specifiy the thread that should be used.
    */
    public init(identifier: UUID, modules: [Module], dispatchQueue: dispatch_queue_t) {
        self.identifier = identifier
        self.router = DefaultRouter(localIdentifier: identifier, dispatchQueue: dispatchQueue, modules: modules)
        self.dispatchQueue = dispatchQueue
        
        super.init()
        
        self.router.delegate = self
    }
    
    /**
    * This method starts the local peer. This will advertise the local peer in the network and starts browsing for other peers.
    * Important: You need to set the incomingConnectionBlock property of any discovered peers, otherwise you will not be able to handle incoming connections.
    *
    * @param onPeerDiscovered Called when a peer is discovered.
    * @param onPeerRemoved Called when a peer is removed.
    */
    public func start(#onPeerDiscovered: PeerDiscoveredClosure, onPeerRemoved: PeerRemovedClosure) {
        self.onPeerDiscovered = onPeerDiscovered
        self.onPeerRemoved = onPeerRemoved
        
        self.startRouter()
    }
    /**
    * This method starts the local peer. This will advertise the local peer in the network, starts browsing for other peers, and accepts incoming connections.
    * @param onPeerDiscovered Called when a peer is discovered.
    * @param onPeerRemoved Called when a peer is removed.
    * @param onIncomingConnection Called when a connection is available. Call accept on the peer to accept the connection.
    */
    public func start(
        #onPeerDiscovered: PeerDiscoveredClosure,
        onPeerRemoved: PeerRemovedClosure,
        onIncomingConnection: ConnectionClosure) {
            
        self.onPeerDiscovered = onPeerDiscovered
        self.onPeerRemoved = onPeerRemoved
        self.onConnection = onIncomingConnection
        
        self.startRouter()
    }
    
    /*
    * Stops advertising and browsing.
    */
    public func stop() {
        self.router.stop()
        
        self.onPeerDiscovered = nil
        self.onPeerRemoved = nil
        self.onConnection = nil
    }
    /**
    * Add a module to this LocalPeer. The module will be started immediately if the LocalPeer is already started.
    * @param module The module that should be added.
    */
    public func addModule(module: Module) {
        self.router.addModule(module)
    }
    /**
    * Remove a module from this LocalPeer.
    * @param module The module that should be removed.
    */
    public func removeModule(module: Module) {
        self.router.addModule(module)
    }
    
    // MARK: Establishing multicast connections
    
    /**
    * Establishes a multicast connection to a set of peers. The connection can only be used to send data, not to receive data.
    * @param destinations The RemotePeers to establish a connection with.
    * @return A Connection object. It can be used to send data immediately (the transfers will be started once the connection was successfully established).
    */
    public func connect(destinations: Set<RemotePeer>) -> Connection {
        let destinations = destinations.map { $0.node }
        let identifier = UUID.random()
        let packetConnection = PacketConnection(connection: nil, connectionIdentifier: identifier, destinations: destinations)
        
        self.establishedConnections[identifier] = packetConnection
        
        let transferConnection = Connection(packetConnection: packetConnection, localIdentifier: self.identifier, dispatchQueue: self.dispatchQueue, isConnectionEstablisher: true, connectionManager: self)
        transferConnection.reconnect()
        
        return transferConnection
    }
     
    // MARK: Internal
    private var onPeerDiscovered: PeerDiscoveredClosure? = nil
    private var onPeerRemoved: PeerRemovedClosure? = nil
    var onConnection: ConnectionClosure? = nil
    
    private let router: DefaultRouter
    private var knownPeers: [Node: RemotePeer] = [:]
    private var establishedConnections: [UUID: PacketConnection] = [:]
    private var incomingConnections: [UUID: PacketConnection] = [:]
    
    private func startRouter() {
        if self.router.modules.count == 0 {
            log(.High, warning: "You started the LocalPeer, but it does not have any modules. It cannot function without modules. See the LocalPeer class documentation for more information.")
        }
        
        self.router.start()
    }
    private func providePeer(node: Node) -> RemotePeer {
        return self.knownPeers.getOrDefault(
            node,
            defaultValue: RemotePeer(
                node: node,
                localPeer: self,
                dispatchQueue: self.dispatchQueue
            )
        )
    }
    
    /**
    * Called when ManagedConnectionHandshake was received, i.e. when all necessary information is available to deal with this connection.
    * If the corresponding PacketConnection already exists, its underlying connection is swapped. Otherwise, a new Connection is created.
    *
    * @param router The router which reported the connection
    * @param node The node which established the connection
    * @param connection The connection that was established
    * @param connectionIdentifier The identifier of the connection
    * */
    private func handleConnection(#node: Node, connection: UnderlyingConnection, connectionIdentifier: UUID) {
        let needsToReportPeer = self.knownPeers[node] == nil
        
        let peer = self.providePeer(node)
        
        if needsToReportPeer { self.onPeerDiscovered?(peer: peer) }
        
        if let packetConnection = peer.connections[connectionIdentifier] {
            packetConnection.swapUnderlyingConnection(connection)
        } else {
            self.createConnection(peer: peer, connection: connection, connectionIdentifier: connectionIdentifier)
        }
    }
    /**
    * Creates a new connection and calls the handling closure.
    */
    private func createConnection(#peer: RemotePeer, connection: UnderlyingConnection, connectionIdentifier: UUID) {
        let packetConnection = PacketConnection(
            connection: connection,
            connectionIdentifier: connectionIdentifier,
            destinations: [peer.node]
        )
        peer.connections[connectionIdentifier] = packetConnection
        self.incomingConnections[connectionIdentifier] = packetConnection
        
        let transferConnection = Connection(
            packetConnection: packetConnection,
            localIdentifier: self.identifier,
            dispatchQueue: self.dispatchQueue,
            isConnectionEstablisher: false,
            connectionManager: self
        )
        
        if let connectionClosure = peer.onConnection {
            connectionClosure(peer: peer,connection:  transferConnection)
        } else if let connectionClosure = self.onConnection {
            connectionClosure(peer: peer,connection:  transferConnection)
        } else {
            log(.High, warning: "An incoming connection was received, but onConnection is not set. Set it either in your LocalPeer instance (\(self)), or in the RemotePeer which established the connection (\(peer)).")
        }
    }
    
    // MARK: RouterDelegate
    internal func didFindNode(router: Router, node: Node) {
        if self.knownPeers[node] != nil { return }
        
        let peer = providePeer(node)
        
        self.onPeerDiscovered?(peer: peer)
    }
    internal func didImproveRoute(router: Router, node: Node) {
        self.reconnect(self.providePeer(node))
    }
    internal func didLoseNode(router: Router, node: Node) {
        let peer = providePeer(node)
        self.knownPeers[node] = nil
        peer.onConnection = nil
        self.onPeerRemoved?(peer: peer)
    }
    /**
    * Handles an incoming connection.
    *
    * @param router The router which reported the connection
    * @param node The node which established the connection
    * @param connection The connection that was established
    * */
    internal func handleConnection(router: Router, node: Node, connection: UnderlyingConnection) {
        log(.High, info: "Handling incoming connection...")
        readSinglePacket(
            connection: connection,
            onPacket: {
                data in
                if let packet = ManagedConnectionHandshake.deserialize(data) {
                    self.handleConnection(node: node, connection: connection, connectionIdentifier: packet.connectionIdentifier)
                } else {
                    println("Expected ManagedConnectionHandshake.")
                }
            },
            onFail: {
                println("Connection closed before receiving ManagedConnectionHandshake")
            }
        )
    }
    
    // MARK: ConnectionDelegate
    func establishUnderlyingConnection(packetConnection: PacketConnection) {
        self.router.establishMulticastConnection(
            destinations: packetConnection.destinations,
            onConnection: {
                connection in
                writeSinglePacket(
                    connection: connection,
                    packet: ManagedConnectionHandshake(connectionIdentifier: packetConnection.connectionIdentifier),
                    onSuccess: { packetConnection.swapUnderlyingConnection(connection) },
                    onFail: { log(.Medium, error: "Failed to send ManagedConnectionHandshake.") }
                )
            },
            onFail: { log(.Medium, error: "Failed to establish connection.") }
        )
    }
    
    func notifyConnectionClose(connection: PacketConnection) {
        self.establishedConnections[connection.connectionIdentifier] = nil
        self.incomingConnections[connection.connectionIdentifier] = nil
    }
    func reconnect(peer: RemotePeer) {
        for (identifier, packetConnection) in self.establishedConnections {
            if packetConnection.destinations.contains(peer.node) {
                self.establishUnderlyingConnection(packetConnection)
            }
        }
    }
}