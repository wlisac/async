import Dispatch
import Foundation

/// Data stream wrapper for a dispatch socket.
public final class SocketSink<Socket>: InputStream
    where Socket: Async.Socket
{
    /// See InputStream.Input
    public typealias Input = UnsafeBufferPointer<UInt8>

    /// The client stream's underlying socket.
    public var socket: Socket

    /// Data being fed into the client stream is stored here.
    private var inputBuffer: UnsafeBufferPointer<UInt8>?
    
    /// Stores write event source.
    private var writeSource: EventSource?

    /// A strong reference to the current eventloop
    private var eventLoop: EventLoop

    /// True if this sink has been closed
    private var isClosed: Bool

    private var awaitingReady: (() -> ())?

    /// Creates a new `SocketSink`
    internal init(socket: Socket, on worker: Worker) {
        self.socket = socket
        self.eventLoop = worker.eventLoop
        self.inputBuffer = nil
        self.isClosed = false
        let writeSource = self.eventLoop.onWritable(descriptor: socket.descriptor, writeSourceSignal)
        self.writeSource = writeSource
    }

    /// See InputStream.input
    public func input(_ event: InputEvent<UnsafeBufferPointer<UInt8>>) {
        // update variables
        switch event {
        case .next(let input, let ready):
            guard inputBuffer == nil else {
                fatalError("SocketSink upstream is illegally overproducing input buffers.")
            }
            inputBuffer = input
            writeData(done: ready)
        case .close:
            close()
        case .error(let e):
            close()
            fatalError("\(e)")
        }
    }

    /// Cancels reading
    public func close() {
        guard !isClosed else {
            return
        }
        guard let writeSource = self.writeSource else {
            fatalError("SocketSink writeSource illegally nil during close.")
        }
        writeSource.cancel()
        socket.close()
        self.writeSource = nil
        isClosed = true
    }

    /// Writes the buffered data to the socket.
    private func writeData(done: @escaping () -> ()) {
        do {
            guard let buffer = self.inputBuffer else {
                fatalError("Unexpected nil SocketSink inputBuffer during writeData")
            }

            let write = try socket.write(from: buffer) // FIXME: add an error handler
            switch write {
            case .wrote(let count):
                switch count {
                case buffer.count:
                    self.inputBuffer = nil
                    done()
                default:
                    inputBuffer = UnsafeBufferPointer<UInt8>(
                        start: buffer.baseAddress?.advanced(by: count),
                        count: buffer.count - count
                    )
                    writeData(done: done)
                }
            case .wouldBlock:
                guard let writeSource = self.writeSource else {
                    fatalError("SocketSink writeSource illegally nil during writeData.")
                }

                // always suspend, we will resume on next input
                writeSource.resume()
                awaitingReady = done
            }
        } catch {
            self.error(error)
            done()
        }
    }

    /// Called when the write source signals.
    private func writeSourceSignal(isCancelled: Bool) {
        guard !isCancelled else {
            // source is cancelled, we will never receive signals again
            close()
            return
        }

        guard let writeSource = self.writeSource else {
            fatalError("SocketSink writeSource illegally nil during signal.")
        }
        // always suspend, we will resume on next input
        writeSource.suspend()

        guard let done = awaitingReady else {
            fatalError("SocketSink awaitingReady illegaly nil during signal.")
        }
        writeData(done: done)
    }
}

/// MARK: Create

extension Socket {
    /// Creates a data stream for this socket on the supplied event loop.
    public func sink(on eventLoop: Worker) -> SocketSink<Self> {
        return .init(socket: self, on: eventLoop)
    }
}
