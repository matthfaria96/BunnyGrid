import Foundation
import JavaScriptCore

/// What a JavaScript shell script produced: the printed lines and the value of the last expression, as shell outputs.
public struct MongoJavaScriptResult: Sendable {
    public var outputs: [MongoShellOutput]
    /// The database the script ended in (after `use`).
    public var database: String
    public var printed: [String]
}

/// Runs mongosh-style JavaScript in JavaScriptCore: variables, loops, functions, `db.coll.method(…)` with cursors
/// (`sort` / `limit` / `skip` / `projection` / `toArray` / `forEach` / `map` / `next` / `hasNext` / `count`),
/// `use` / `show`, `print` / `printjson`, and the BSON constructors (`ObjectId`, `ISODate`, `NumberLong`, `NumberInt`,
/// `NumberDecimal`, `UUID`, `BinData`, `Timestamp`, `MinKey`, `MaxKey`). Every database call goes through
/// `MongoShellExecutor`, so the commands behave as in the statement shell. The script runs on its own thread; a
/// database call blocks it while the driver works. Cancelling the task (or the time limit, counted in JavaScript time
/// only) stops the script; a running command is stopped with the driver's `killOp`.
public final class MongoJavaScriptShell: @unchecked Sendable {
    public let driver: MongoDriver
    public private(set) var database: String
    public var timeLimit: Duration
    /// Most documents a cursor brings into the script (`toArray`, `forEach`…).
    public var iterationLimit = 100_000

    private let lock = NSLock()
    private var cancelled = false
    private var started = ContinuousClock.now
    private var bridgeTime: Duration = .zero
    private var printed: [String] = []
    private var lastError: Error?
    /// Sets the watchdog's limit again (from its callback, on the script thread).
    fileprivate var rearm: ((JSContextGroupRef?) -> Void)?

    public init(driver: MongoDriver, database: String, timeLimit: Duration = .seconds(60)) {
        self.driver = driver
        self.database = database
        self.timeLimit = timeLimit
    }

    public func run(_ script: String, maxDocuments: Int) async throws -> MongoJavaScriptResult {
        lock.withLock { cancelled = false }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<MongoJavaScriptResult, Error>) in
                let thread = Thread { [self] in
                    continuation.resume(with: Result { try self.evaluate(script, maxDocuments: maxDocuments) })
                }
                thread.stackSize = 8 << 20
                thread.name = "BunnyGrid Mongo JavaScript"
                thread.start()
            }
        } onCancel: {
            lock.withLock { cancelled = true }
            let driver = driver
            Task { try? await driver.cancelCurrentQuery() }
        }
    }

    private var isCancelled: Bool { lock.withLock { cancelled } }

    /// True once the script has used up its JavaScript time (database calls don't count).
    fileprivate var shouldTerminate: Bool {
        lock.withLock { cancelled || (ContinuousClock.now - started - bridgeTime) > timeLimit }
    }

    // MARK: - Evaluation (on the script thread)

    private func evaluate(_ script: String, maxDocuments: Int) throws -> MongoJavaScriptResult {
        guard let context = JSContext() else { throw DatabaseError.queryFailed("JavaScriptCore is unavailable.") }
        started = .now
        bridgeTime = .zero
        printed = []
        lastError = nil
        let watchdog = Watchdog(shell: self)
        watchdog.install(on: context)

        var exception: JSValue?
        context.exceptionHandler = { _, value in exception = value }
        installNatives(in: context)
        context.evaluateScript(Self.prelude)
        if let exception { throw DatabaseError.queryFailed("Shell prelude failed: \(exception)") }
        context.objectForKeyedSubscript("__setDB").call(withArguments: [database])

        let value = context.evaluateScript(Self.preprocess(script), withSourceURL: URL(string: "script.js"))
        if let thrown = exception {
            throw scriptError(thrown)
        }
        var outputs: [MongoShellOutput] = []
        if !printed.isEmpty {
            outputs.append(MongoShellOutput(statement: "print", content: .value(.string(printed.joined(separator: "\n")))))
        }
        let described = context.objectForKeyedSubscript("__finalize").call(withArguments: [value ?? JSValue(undefinedIn: context)!])
        if let thrown = exception { throw scriptError(thrown) }
        let text = described?.toString() ?? "{}"
        let final = try Self.parse(text)
        switch final["kind"]?.stringValue {
        case "cursor":
            guard let spec = final["spec"]?.documentValue else { break }
            outputs.append(try execute(spec, maxDocuments: maxDocuments, statementText: script))
        case "value":
            let result = final["value"] ?? .undefined
            if case .array(let items) = result, !items.isEmpty, items.allSatisfy({ $0.documentValue != nil }) {
                outputs.append(MongoShellOutput(statement: script, content: .documents(items.compactMap(\.documentValue), truncated: false)))
            } else {
                outputs.append(MongoShellOutput(statement: script, content: .value(result)))
            }
        default:
            if outputs.isEmpty { outputs.append(MongoShellOutput(statement: script, content: .message("Script ran."))) }
        }
        outputs = outputs.map { var o = $0; o.duration = ContinuousClock.now - started; return o }
        return MongoJavaScriptResult(outputs: outputs, database: database, printed: printed)
    }

    private func scriptError(_ thrown: JSValue) -> Error {
        if isCancelled { return CancellationError() }
        let message = thrown.toString() ?? "JavaScript error"
        if message.contains("terminated") || message.contains("Terminat") {
            return DatabaseError.queryFailed("The script ran longer than \(timeLimit.components.seconds) s of JavaScript time and was stopped.")
        }
        if let lastError, message == "Error: \(lastError.localizedDescription)" || message.hasSuffix(lastError.localizedDescription) {
            return lastError
        }
        let line = thrown.objectForKeyedSubscript("line")
        if let line, line.isNumber { return DatabaseError.queryFailed("\(message) (line \(line.toInt32()))") }
        return DatabaseError.queryFailed(message)
    }

    /// `use db` and `show what` lines aren't JavaScript: they become `use("db")` / `show("what")` calls.
    static func preprocess(_ script: String) -> String {
        script.components(separatedBy: "\n").map { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let parts = trimmed.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2, parts[0] == "use" || parts[0] == "show" else { return line }
            var argument = parts[1].trimmingCharacters(in: .whitespaces)
            if argument.hasSuffix(";") { argument.removeLast() }
            guard !argument.isEmpty, argument.allSatisfy({ $0.isLetter || $0.isNumber || "_-.$".contains($0) }) else { return line }
            return "\(parts[0])(\(BSONFormat.quote(argument)));"
        }.joined(separator: "\n")
    }

    // MARK: - Natives

    private func installNatives(in context: JSContext) {
        let call: @convention(block) (String) -> String = { [unowned self] specText in
            do {
                let spec = try Self.parse(specText)
                let output = try self.execute(spec, maxDocuments: spec["max"]?.intValue ?? self.iterationLimit, statementText: "")
                return Self.describe(output)
            } catch {
                self.lastError = error
                let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                JSContext.current()?.exception = JSValue(newErrorFromMessage: message, in: JSContext.current())
                return "{}"
            }
        }
        let print: @convention(block) (String) -> Void = { [unowned self] line in printed.append(line) }
        let format: @convention(block) (String) -> String = { text in
            guard let value = try? MongoShellParser.parseValue(text) else { return text }
            return BSONFormat.shell(value)
        }
        let newObjectId: @convention(block) () -> String = { ObjectId().hexString }
        let newUUID: @convention(block) () -> String = { UUID().uuidString.lowercased() }
        let sleep: @convention(block) (Double) -> Void = { [unowned self] ms in
            let start = ContinuousClock.now
            var remaining = max(0, ms) / 1000
            while remaining > 0, !isCancelled {
                Thread.sleep(forTimeInterval: min(remaining, 0.1))
                remaining -= 0.1
            }
            lock.withLock { bridgeTime += ContinuousClock.now - start }
        }
        let natives = JSValue(newObjectIn: context)!
        natives.setObject(call, forKeyedSubscript: "call" as NSString)
        natives.setObject(print, forKeyedSubscript: "print" as NSString)
        natives.setObject(format, forKeyedSubscript: "format" as NSString)
        natives.setObject(newObjectId, forKeyedSubscript: "objectId" as NSString)
        natives.setObject(newUUID, forKeyedSubscript: "uuid" as NSString)
        natives.setObject(sleep, forKeyedSubscript: "sleep" as NSString)
        context.setObject(natives, forKeyedSubscript: "__native" as NSString)
    }

    /// Runs one database call described by the script: `{db, target, collection, calls: [{name, args}]}`.
    private func execute(_ spec: BSONDocument, maxDocuments: Int, statementText: String) throws -> MongoShellOutput {
        if isCancelled { throw CancellationError() }
        let db = spec["db"]?.stringValue ?? database
        let calls: [MongoShellCall] = (spec["calls"]?.arrayValue ?? []).compactMap { item in
            guard let call = item.documentValue, let name = call["name"]?.stringValue else { return nil }
            return MongoShellCall(name, call["args"]?.arrayValue ?? [])
        }
        let target: MongoShellStatement.Target
        switch spec["target"]?.stringValue {
        case "collection": target = .collection(spec["collection"]?.stringValue ?? "")
        case "use":
            database = spec["name"]?.stringValue ?? database
            return MongoShellOutput(statement: statementText, content: .message("switched to db \(database)"), switchedDatabase: database)
        case "show": target = .show(spec["name"]?.stringValue ?? "")
        default: target = .database
        }
        let statement = MongoShellStatement(target: target, database: db, calls: calls, text: statementText)
        let executor = MongoShellExecutor(driver: driver, database: db)
        let box = ResultBox()
        let semaphore = DispatchSemaphore(value: 0)
        let start = ContinuousClock.now
        Task {
            do { box.result = .success(try await executor.run(statement, maxDocuments: max(1, maxDocuments))) } catch { box.result = .failure(error) }
            semaphore.signal()
        }
        semaphore.wait()
        lock.withLock { bridgeTime += ContinuousClock.now - start }
        return try box.result!.get()
    }

    private final class ResultBox: @unchecked Sendable {
        var result: Result<MongoShellOutput, Error>?
    }

    /// The reply of a native call, as Extended JSON the prelude revives.
    static func describe(_ output: MongoShellOutput) -> String {
        switch output.content {
        case .documents(let documents, let truncated):
            return "{\"kind\":\"documents\",\"truncated\":\(truncated),\"value\":\(json(.array(documents.map(BSON.document))))}"
        case .value(let value):
            return "{\"kind\":\"value\",\"value\":\(json(value))}"
        case .plan(let plan):
            return "{\"kind\":\"value\",\"value\":\(json(.document(plan)))}"
        case .message(let text):
            return "{\"kind\":\"message\",\"value\":\(BSONFormat.quote(text))}"
        }
    }

    /// Relaxed Extended JSON, with Int64 values JavaScript can't hold exactly kept as `{"$numberLong": …}`.
    static func json(_ value: BSON) -> String {
        func wrap(_ value: BSON) -> BSON {
            switch value {
            case .int64(let v) where abs(v) > (1 << 53): return .document(["$numberLong": .string(String(v))])
            case .document(let d): return .document(BSONDocument(d.elements.map { BSONElement($0.key, wrap($0.value)) }))
            case .array(let a): return .array(a.map(wrap))
            default: return value
            }
        }
        return BSONFormat.extendedJSON(wrap(value))
    }

    static func parse(_ text: String) throws -> BSONDocument {
        guard case .document(let document) = try MongoShellParser.parseValue(text) else {
            throw DatabaseError.queryFailed("Unexpected reply from the script.")
        }
        return document
    }

    // MARK: - Watchdog

    /// Stops runaway JavaScript through JavaScriptCore's execution time limit (exported by the framework, though
    /// only declared in its private header); without it, cancelling still stops the script at its next database call.
    private final class Watchdog {
        typealias Callback = @convention(c) (JSContextRef?, UnsafeMutableRawPointer?) -> Bool
        typealias SetLimit = @convention(c) (JSContextGroupRef?, Double, Callback?, UnsafeMutableRawPointer?) -> Void
        unowned let shell: MongoJavaScriptShell

        init(shell: MongoJavaScriptShell) { self.shell = shell }

        func install(on context: JSContext) {
            guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "JSContextGroupSetExecutionTimeLimit") else { return }
            let setLimit = unsafeBitCast(symbol, to: SetLimit.self)
            let group = JSContextGetGroup(context.jsGlobalContextRef)
            let info = Unmanaged.passUnretained(shell).toOpaque()
            // When the callback returns false JavaScriptCore doesn't always start the timer again (seen under load),
            // so the callback sets the limit itself before letting the script go on.
            let callback: Callback = { context, info in
                guard let info else { return true }
                let shell = Unmanaged<MongoJavaScriptShell>.fromOpaque(info).takeUnretainedValue()
                if shell.shouldTerminate { return true }
                if let context, let rearm = shell.rearm { rearm(JSContextGetGroup(context)) }
                return false
            }
            shell.rearm = { group in setLimit(group, 0.2, callback, info) }
            setLimit(group, 0.2, callback, info)
        }
    }

    // MARK: - Prelude

    static let prelude = #"""
    (function (global) {
      const N = __native;
      let currentDB = "test";
      function hex(n, w) { return n.toString(16).padStart(w, "0"); }

      function ObjectId(h) {
        if (!(this instanceof ObjectId)) return new ObjectId(h);
        const s = h === undefined ? N.objectId() : String(h && h.$oid ? h.$oid : h);
        if (!/^[0-9a-fA-F]{24}$/.test(s)) throw new Error("ObjectId needs 24 hex digits");
        this.$oid = s.toLowerCase();
      }
      ObjectId.prototype.toString = function () { return 'ObjectId("' + this.$oid + '")'; };
      ObjectId.prototype.toHexString = function () { return this.$oid; };
      ObjectId.prototype.valueOf = function () { return this.$oid; };
      ObjectId.prototype.equals = function (o) { return !!o && o.$oid === this.$oid; };
      ObjectId.prototype.getTimestamp = function () { return new Date(parseInt(this.$oid.slice(0, 8), 16) * 1000); };
      ObjectId.prototype.__ejson = function () { return { $oid: this.$oid }; };
      global.ObjectId = global.ObjectID = ObjectId;

      function wrapper(name, make) {
        const C = function (...args) {
          if (!(this instanceof C)) return new C(...args);
          make.apply(this, args);
        };
        Object.defineProperty(C, "name", { value: name });
        global[name] = C;
        return C;
      }
      const Long = wrapper("NumberLong", function (v) {
        const s = String(v === undefined ? 0 : (v && v.$numberLong) || v);
        if (!/^-?\d+$/.test(s)) throw new Error("NumberLong needs an integer");
        this.$numberLong = s;
      });
      Long.prototype.valueOf = function () { return Number(this.$numberLong); };
      Long.prototype.toNumber = Long.prototype.valueOf;
      Long.prototype.toString = function () { return "NumberLong(" + this.$numberLong + ")"; };
      Long.prototype.__ejson = function () { return { $numberLong: this.$numberLong }; };
      global.Long = Long;
      const Int = wrapper("NumberInt", function (v) { this.value = (Number(v) || 0) | 0; });
      Int.prototype.valueOf = function () { return this.value; };
      Int.prototype.toString = function () { return "NumberInt(" + this.value + ")"; };
      Int.prototype.__ejson = function () { return { $numberInt: String(this.value) }; };
      global.Int32 = Int;
      const Dec = wrapper("NumberDecimal", function (v) { this.$numberDecimal = String(v === undefined ? "0" : (v && v.$numberDecimal) || v); });
      Dec.prototype.valueOf = function () { return Number(this.$numberDecimal); };
      Dec.prototype.toString = function () { return 'NumberDecimal("' + this.$numberDecimal + '")'; };
      Dec.prototype.__ejson = function () { return { $numberDecimal: this.$numberDecimal }; };
      global.Decimal128 = Dec;
      const Bin = wrapper("BinData", function (subType, base64) { this.subType = subType | 0; this.base64 = String(base64); });
      Bin.prototype.toString = function () { return "BinData(" + this.subType + ', "' + this.base64 + '")'; };
      Bin.prototype.__ejson = function () { return { $binary: { base64: this.base64, subType: hex(this.subType, 2) } }; };
      const Uuid = wrapper("UUID", function (s) {
        const text = (s === undefined ? N.uuid() : String(s)).replace(/-/g, "").toLowerCase();
        if (!/^[0-9a-f]{32}$/.test(text)) throw new Error("Invalid UUID");
        this.uuid = text.slice(0, 8) + "-" + text.slice(8, 12) + "-" + text.slice(12, 16) + "-" + text.slice(16, 20) + "-" + text.slice(20);
      });
      Uuid.prototype.toString = function () { return 'UUID("' + this.uuid + '")'; };
      Uuid.prototype.__ejson = function () { return { $uuid: this.uuid }; };
      const Ts = wrapper("Timestamp", function (t, i) {
        if (t && typeof t === "object") { i = t.i; t = t.t; }
        this.t = t >>> 0; this.i = i >>> 0;
      });
      Ts.prototype.toString = function () { return "Timestamp(" + this.t + ", " + this.i + ")"; };
      Ts.prototype.__ejson = function () { return { $timestamp: { t: this.t, i: this.i } }; };
      const Min = wrapper("MinKey", function () {});
      Min.prototype.__ejson = function () { return { $minKey: 1 }; };
      const Max = wrapper("MaxKey", function () {});
      Max.prototype.__ejson = function () { return { $maxKey: 1 }; };
      global.ISODate = function (s) { return s === undefined ? new Date() : new Date(s); };

      function toEJSON(v) {
        if (v === null) return null;
        if (v === undefined) return undefined;
        if (typeof v === "number") {
          if (!isFinite(v)) return { $numberDouble: isNaN(v) ? "NaN" : (v < 0 ? "-Infinity" : "Infinity") };
          return v;
        }
        if (typeof v === "bigint") return { $numberLong: v.toString() };
        if (typeof v === "string" || typeof v === "boolean") return v;
        if (typeof v === "function") return undefined;
        if (v instanceof Date) return { $date: { $numberLong: String(v.getTime()) } };
        if (v instanceof RegExp) return { $regularExpression: { pattern: v.source, options: v.flags.replace(/[^imsux]/g, "") } };
        if (typeof v.__ejson === "function") return v.__ejson();
        if (v instanceof Number || v instanceof String || v instanceof Boolean) return v.valueOf();
        if (v instanceof DBCursor) return toEJSON(v.toArray());
        if (Array.isArray(v)) return v.map(x => { const e = toEJSON(x); return e === undefined ? null : e; });
        const out = {};
        for (const k of Object.keys(v)) { const e = toEJSON(v[k]); if (e !== undefined) out[k] = e; }
        return out;
      }

      function revive(k, v) {
        if (!v || typeof v !== "object" || Array.isArray(v)) return v;
        const keys = Object.keys(v);
        if (keys.length === 1) {
          const x = v[keys[0]];
          switch (keys[0]) {
            case "$oid": return new ObjectId(x);
            case "$date": return new Date(typeof x === "string" ? x : Number(x));
            case "$numberLong": return new Long(x);
            case "$numberInt": return Number(x);
            case "$numberDouble": return Number(x);
            case "$numberDecimal": return new Dec(x);
            case "$binary":
              if (x.subType === "04") { const b = atobHex(x.base64); if (b) return new Uuid(b); }
              return new Bin(parseInt(x.subType, 16), x.base64);
            case "$uuid": return new Uuid(x);
            case "$regularExpression": try { return new RegExp(x.pattern, x.options.replace(/[^imsu]/g, "")); } catch (e) { return v; }
            case "$timestamp": return new Ts(x.t, x.i);
            case "$minKey": return new Min();
            case "$maxKey": return new Max();
            case "$undefined": return undefined;
          }
        }
        return v;
      }
      const B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
      function atobHex(b64) {
        let bits = 0, n = 0, out = "";
        for (const c of b64.replace(/=+$/, "")) {
          const i = B64.indexOf(c); if (i < 0) return null;
          bits = (bits << 6) | i; n += 6;
          if (n >= 8) { n -= 8; out += hex((bits >> n) & 0xff, 2); }
        }
        return out.length === 32 ? out : null;
      }

      function call(spec) {
        spec.db = spec.db || currentDB;
        const reply = JSON.parse(N.call(JSON.stringify(toEJSON(spec))), revive);
        return reply;
      }
      function value(spec) { return call(spec).value; }

      function DBCursor(collection, kind, args) {
        this._c = collection; this._kind = kind; this._args = args; this._chain = []; this._docs = null; this._i = 0;
      }
      for (const m of ["sort", "limit", "skip", "projection", "hint", "collation", "maxTimeMS", "batchSize", "comment", "allowDiskUse"]) {
        DBCursor.prototype[m] = function (...args) { this._chain.push({ name: m, args }); this._docs = null; return this; };
      }
      DBCursor.prototype.pretty = function () { return this; };
      DBCursor.prototype._spec = function (extra) {
        return { db: this._c._db, target: "collection", collection: this._c._name,
                 calls: [{ name: this._kind, args: this._args }].concat(this._chain, extra || []) };
      };
      DBCursor.prototype.toArray = function () {
        if (!this._docs) this._docs = value(this._spec());
        return this._docs;
      };
      DBCursor.prototype.forEach = function (f) { this.toArray().forEach(f); };
      DBCursor.prototype.map = function (f) { return this.toArray().map(f); };
      DBCursor.prototype.hasNext = function () { return this._i < this.toArray().length; };
      DBCursor.prototype.next = function () { const d = this.toArray(); return this._i < d.length ? d[this._i++] : null; };
      DBCursor.prototype.tryNext = DBCursor.prototype.next;
      DBCursor.prototype[Symbol.iterator] = function* () { yield* this.toArray(); };
      DBCursor.prototype.count = function () { return this._kind === "find" ? value(this._spec([{ name: "count", args: [] }])) : this.toArray().length; };
      DBCursor.prototype.itcount = function () { return this.toArray().length; };
      DBCursor.prototype.size = DBCursor.prototype.count;
      DBCursor.prototype.explain = function () { return value(this._spec([{ name: "explain", args: [] }])); };
      DBCursor.prototype.toString = function () { return "DBCursor"; };

      function Collection(db, name) {
        this._db = db; this._name = name;
        return new Proxy(this, { get(target, prop, receiver) {
          if (prop in target || typeof prop === "symbol") return Reflect.get(target, prop, receiver);
          return new Collection(db, name + "." + prop);
        } });
      }
      const cursorMethods = ["find", "aggregate"];
      const collectionMethods = ["findOne", "countDocuments", "count", "estimatedDocumentCount", "distinct", "insertOne", "insertMany", "insert",
        "updateOne", "updateMany", "replaceOne", "deleteOne", "deleteMany", "remove", "createIndex", "ensureIndex", "dropIndex",
        "dropIndexes", "getIndexes", "getIndices", "drop", "stats", "storageStats", "renameCollection"];
      for (const m of cursorMethods) {
        Collection.prototype[m] = function (...args) {
          if (m === "aggregate" && args.length && !Array.isArray(args[0])) args = [args];
          while (args.length && args[args.length - 1] === undefined) args.pop();
          return new DBCursor(this, m, args);
        };
      }
      for (const m of collectionMethods) {
        Collection.prototype[m] = function (...args) {
          while (args.length && args[args.length - 1] === undefined) args.pop();
          return value({ db: this._db, target: "collection", collection: this._name, calls: [{ name: m, args }] });
        };
      }
      Collection.prototype.getName = function () { return this._name; };
      Collection.prototype.getFullName = function () { return this._db + "." + this._name; };
      Collection.prototype.toString = function () { return this._db + "." + this._name; };

      function DB(name) {
        this._name = name;
        return new Proxy(this, { get(target, prop, receiver) {
          if (prop in target || typeof prop === "symbol") return Reflect.get(target, prop, receiver);
          return new Collection(name, String(prop));
        } });
      }
      for (const m of ["runCommand", "adminCommand", "createCollection", "createView", "getCollectionNames", "dropDatabase", "stats", "version"]) {
        DB.prototype[m] = function (...args) { return value({ db: this._name, target: "database", calls: [{ name: m, args }] }); };
      }
      DB.prototype.aggregate = function (pipeline) {
        const c = new Collection(this._name, ""); const cur = new DBCursor(c, "aggregate", [pipeline]);
        cur._spec = function (extra) { return { db: c._db, target: "database", calls: [{ name: "aggregate", args: [pipeline] }].concat(extra || []) }; };
        return cur;
      };
      DB.prototype.getName = function () { return this._name; };
      DB.prototype.getCollection = function (n) { return new Collection(this._name, String(n)); };
      DB.prototype.getSiblingDB = function (n) { return new DB(String(n)); };
      DB.prototype.getMongo = function () { return { getDB: n => new DB(String(n)) }; };
      DB.prototype.toString = function () { return this._name; };

      global.__setDB = function (n) { currentDB = n; global.db = new DB(n); };
      global.use = function (n) { call({ target: "use", name: String(n) }); global.__setDB(String(n)); return "switched to db " + n; };
      global.show = function (what) { return value({ target: "show", name: String(what) }); };
      function inspect(v) {
        if (typeof v === "string") return v;
        if (v === undefined) return "undefined";
        if (v instanceof DBCursor) v = v.toArray();
        return N.format(JSON.stringify(toEJSON(v)));
      }
      global.print = function (...args) { N.print(args.map(inspect).join(" ")); };
      global.printjson = function (v) { N.print(N.format(JSON.stringify(toEJSON(v instanceof DBCursor ? v.toArray() : v)))); };
      global.console = { log: global.print, info: global.print, warn: global.print, error: global.print };
      global.sleep = function (ms) { N.sleep(Number(ms) || 0); };
      global.tojson = function (v) { return N.format(JSON.stringify(toEJSON(v))); };
      global.EJSON = { stringify: v => JSON.stringify(toEJSON(v)), parse: s => JSON.parse(s, revive) };
      global.__finalize = function (v) {
        if (v instanceof DBCursor) {
          if (v._docs) return JSON.stringify({ kind: "value", value: toEJSON(v._docs) });
          return JSON.stringify({ kind: "cursor", spec: toEJSON(v._spec()) });
        }
        if (v === undefined || typeof v === "function" || (v && v instanceof DB)) return JSON.stringify({ kind: "none" });
        if (v && v instanceof Collection) return JSON.stringify({ kind: "value", value: String(v) });
        const e = toEJSON(v);
        return JSON.stringify(e === undefined ? { kind: "none" } : { kind: "value", value: e });
      };
    })(this);
    """#
}
