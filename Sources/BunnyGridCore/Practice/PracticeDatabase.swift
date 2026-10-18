import Foundation
import SQLite3

/// A ready-made schema with sample rows for the practice databases: SQLite files that need nothing installed,
/// for learning SQL, trying an idea or testing an app.
public struct PracticeTemplate: Identifiable, Sendable, Hashable {
    public struct ExampleQuery: Sendable, Hashable {
        public let name: String
        public let sql: String
    }

    public let id: String
    public let name: String
    public let summary: String
    /// SF Symbol.
    public let symbol: String
    /// Tile colour, 0xRRGGBB.
    public let tint: UInt32
    public let tables: [String]
    public let script: String
    /// Saved into the database's Queries folder so there is something to open and run right away.
    public let examples: [ExampleQuery]
}

public enum PracticeDatabase {
    public enum CreateError: LocalizedError {
        case open(String)
        case script(String)

        public var errorDescription: String? {
            switch self {
            case .open(let message): "Could not create the database file: \(message)"
            case .script(let message): "Could not build the sample database: \(message)"
            }
        }
    }

    /// `name.sqlite` in `directory`, or `name 2.sqlite`, `name 3.sqlite`… when taken.
    public static func availableURL(named name: String, in directory: URL) -> URL {
        let base = sanitized(name)
        var url = directory.appending(path: "\(base).sqlite")
        var number = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appending(path: "\(base) \(number).sqlite")
            number += 1
        }
        return url
    }

    /// File-name-safe version of a database name; empty becomes "bunnygrid".
    public static func sanitized(_ name: String) -> String {
        let cleaned = name.components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|")).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        return cleaned.isEmpty ? "bunnygrid" : String(cleaned.prefix(80))
    }

    /// Creates a new SQLite file at `url` with the template's tables and rows, in one transaction.
    /// Nothing is left behind when the script fails.
    public static func create(_ template: PracticeTemplate, at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_EXCLUSIVE, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(db)
            throw CreateError.open(message)
        }
        var failure: String?
        let script = "PRAGMA foreign_keys = ON;\nBEGIN;\n" + template.script + "\nCOMMIT;"
        var error: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, script, nil, nil, &error) != SQLITE_OK {
            failure = error.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(error)
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
        }
        sqlite3_close(db)
        if let failure {
            try? FileManager.default.removeItem(at: url)
            throw CreateError.script(failure)
        }
    }

    public static let templates: [PracticeTemplate] = [saas, notes, finance, tasks, store, blog, empty]

    public static func template(id: String) -> PracticeTemplate? { templates.first { $0.id == id } }

    // MARK: - Templates

    static let empty = PracticeTemplate(
        id: "empty", name: "Empty", summary: "A blank database. Create your own tables with New Table or SQL.",
        symbol: "square.dashed", tint: 0x8E8E93, tables: [],
        script: "",
        examples: [PracticeTemplate.ExampleQuery(name: "Getting started", sql: """
            -- Create a table, add a row and read it back. Run with ⌘R.
            CREATE TABLE IF NOT EXISTS people (
                id INTEGER PRIMARY KEY,
                name TEXT NOT NULL,
                created_at TEXT DEFAULT CURRENT_TIMESTAMP
            );
            INSERT INTO people (name) VALUES ('Ana');
            SELECT * FROM people;
            """)]
    )

    static let saas = PracticeTemplate(
        id: "saas", name: "SaaS", summary: "Plans, customer companies, users, subscriptions and invoices: the core of a subscription app.",
        symbol: "building.2.fill", tint: 0x5E5CE6, tables: ["plans", "organizations", "users", "subscriptions", "invoices"],
        script: """
            CREATE TABLE plans (
                id INTEGER PRIMARY KEY,
                name TEXT NOT NULL UNIQUE,
                monthly_price REAL NOT NULL,
                max_users INTEGER NOT NULL
            );
            CREATE TABLE organizations (
                id INTEGER PRIMARY KEY,
                name TEXT NOT NULL,
                country TEXT NOT NULL,
                created_at TEXT NOT NULL
            );
            CREATE TABLE users (
                id INTEGER PRIMARY KEY,
                organization_id INTEGER NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
                name TEXT NOT NULL,
                email TEXT NOT NULL UNIQUE,
                role TEXT NOT NULL CHECK (role IN ('owner', 'admin', 'member')),
                last_login_at TEXT
            );
            CREATE TABLE subscriptions (
                id INTEGER PRIMARY KEY,
                organization_id INTEGER NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
                plan_id INTEGER NOT NULL REFERENCES plans(id),
                status TEXT NOT NULL CHECK (status IN ('trialing', 'active', 'past_due', 'canceled')),
                started_at TEXT NOT NULL,
                canceled_at TEXT
            );
            CREATE TABLE invoices (
                id INTEGER PRIMARY KEY,
                subscription_id INTEGER NOT NULL REFERENCES subscriptions(id) ON DELETE CASCADE,
                amount REAL NOT NULL,
                issued_at TEXT NOT NULL,
                paid_at TEXT
            );
            INSERT INTO plans VALUES (1, 'Free', 0, 3), (2, 'Pro', 29, 20), (3, 'Business', 99, 200);
            INSERT INTO organizations VALUES
                (1, 'Acme Bakery', 'Brazil', '2026-01-10'), (2, 'Nimbus Labs', 'Portugal', '2026-02-03'),
                (3, 'Orbit Travel', 'United States', '2026-03-15'), (4, 'Pixel Pets', 'Brazil', '2026-05-21'),
                (5, 'Quill & Co', 'Spain', '2026-07-08');
            INSERT INTO users VALUES
                (1, 1, 'Ana Souza', 'ana@acmebakery.test', 'owner', '2026-10-17 09:12'),
                (2, 1, 'Bruno Lima', 'bruno@acmebakery.test', 'member', '2026-10-15 18:40'),
                (3, 2, 'Carla Dias', 'carla@nimbus.test', 'owner', '2026-10-18 08:05'),
                (4, 2, 'Diego Rocha', 'diego@nimbus.test', 'admin', '2026-10-16 14:22'),
                (5, 2, 'Eva Martins', 'eva@nimbus.test', 'member', NULL),
                (6, 3, 'Felipe Nunes', 'felipe@orbit.test', 'owner', '2026-09-30 11:00'),
                (7, 4, 'Gabi Torres', 'gabi@pixelpets.test', 'owner', '2026-10-12 20:15'),
                (8, 4, 'Hugo Alves', 'hugo@pixelpets.test', 'member', '2026-10-01 10:10'),
                (9, 5, 'Iris Costa', 'iris@quill.test', 'owner', '2026-08-19 16:45');
            INSERT INTO subscriptions VALUES
                (1, 1, 2, 'active', '2026-01-10', NULL), (2, 2, 3, 'active', '2026-02-03', NULL),
                (3, 3, 2, 'canceled', '2026-03-15', '2026-08-01'), (4, 4, 1, 'trialing', '2026-05-21', NULL),
                (5, 5, 2, 'past_due', '2026-07-08', NULL);
            INSERT INTO invoices VALUES
                (1, 1, 29, '2026-08-10', '2026-08-11'), (2, 1, 29, '2026-09-10', '2026-09-10'), (3, 1, 29, '2026-10-10', NULL),
                (4, 2, 99, '2026-08-03', '2026-08-04'), (5, 2, 99, '2026-09-03', '2026-09-05'), (6, 2, 99, '2026-10-03', '2026-10-03'),
                (7, 3, 29, '2026-07-15', '2026-07-15'), (8, 5, 29, '2026-09-08', NULL), (9, 5, 29, '2026-10-08', NULL);
            """,
        examples: [
            .init(name: "Monthly revenue", sql: """
                -- Paid invoices per month.
                SELECT substr(paid_at, 1, 7) AS month, SUM(amount) AS revenue
                FROM invoices
                WHERE paid_at IS NOT NULL
                GROUP BY month
                ORDER BY month;
                """),
            .init(name: "Customers and their plan", sql: """
                SELECT o.name AS company, p.name AS plan, s.status, COUNT(u.id) AS users
                FROM organizations o
                JOIN subscriptions s ON s.organization_id = o.id
                JOIN plans p ON p.id = s.plan_id
                LEFT JOIN users u ON u.organization_id = o.id
                GROUP BY o.id
                ORDER BY o.name;
                """),
            .init(name: "Unpaid invoices", sql: """
                SELECT o.name AS company, i.amount, i.issued_at
                FROM invoices i
                JOIN subscriptions s ON s.id = i.subscription_id
                JOIN organizations o ON o.id = s.organization_id
                WHERE i.paid_at IS NULL
                ORDER BY i.issued_at;
                """),
        ]
    )

    static let notes = PracticeTemplate(
        id: "notes", name: "Notes", summary: "Notebooks, notes and tags, with a many-to-many link between notes and tags.",
        symbol: "note.text", tint: 0xFFB000, tables: ["notebooks", "notes", "tags", "note_tags"],
        script: """
            CREATE TABLE notebooks (
                id INTEGER PRIMARY KEY,
                name TEXT NOT NULL UNIQUE,
                color TEXT
            );
            CREATE TABLE notes (
                id INTEGER PRIMARY KEY,
                notebook_id INTEGER NOT NULL REFERENCES notebooks(id) ON DELETE CASCADE,
                title TEXT NOT NULL,
                body TEXT,
                pinned INTEGER NOT NULL DEFAULT 0,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL
            );
            CREATE TABLE tags (
                id INTEGER PRIMARY KEY,
                name TEXT NOT NULL UNIQUE
            );
            CREATE TABLE note_tags (
                note_id INTEGER NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
                tag_id INTEGER NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
                PRIMARY KEY (note_id, tag_id)
            );
            INSERT INTO notebooks VALUES (1, 'Personal', 'blue'), (2, 'Work', 'orange'), (3, 'Recipes', 'green');
            INSERT INTO notes VALUES
                (1, 1, 'Groceries', 'Milk, eggs, coffee, bananas', 1, '2026-10-01 08:00', '2026-10-17 19:30'),
                (2, 1, 'Books to read', 'Dune; The Pragmatic Programmer; Sapiens', 0, '2026-09-12 21:10', '2026-09-20 22:00'),
                (3, 2, 'Sprint planning', 'Ship login page, fix export bug, write release notes', 1, '2026-10-14 09:30', '2026-10-14 10:15'),
                (4, 2, 'Meeting with design', 'New colours for the dashboard. Follow up Friday.', 0, '2026-10-16 15:00', '2026-10-16 15:45'),
                (5, 2, 'Ideas', 'Dark mode toggle; keyboard shortcuts cheat sheet', 0, '2026-08-30 11:00', '2026-10-02 09:00'),
                (6, 3, 'Pancakes', '2 eggs, 1 cup flour, 1 cup milk, pinch of salt', 0, '2026-07-04 10:00', '2026-07-04 10:05'),
                (7, 3, 'Brigadeiro', 'Condensed milk, cocoa, butter. Stir until it thickens.', 1, '2026-06-18 17:20', '2026-06-18 17:25');
            INSERT INTO tags VALUES (1, 'urgent'), (2, 'shopping'), (3, 'reading'), (4, 'meeting'), (5, 'sweet');
            INSERT INTO note_tags VALUES (1, 2), (1, 1), (2, 3), (3, 1), (4, 4), (7, 5), (6, 5);
            """,
        examples: [
            .init(name: "Pinned notes", sql: """
                SELECT n.title, nb.name AS notebook, n.updated_at
                FROM notes n JOIN notebooks nb ON nb.id = n.notebook_id
                WHERE n.pinned = 1
                ORDER BY n.updated_at DESC;
                """),
            .init(name: "Notes with their tags", sql: """
                SELECT n.title, group_concat(t.name, ', ') AS tags
                FROM notes n
                LEFT JOIN note_tags nt ON nt.note_id = n.id
                LEFT JOIN tags t ON t.id = nt.tag_id
                GROUP BY n.id
                ORDER BY n.title;
                """),
            .init(name: "Search notes", sql: """
                -- Change the word between the % signs.
                SELECT title, body FROM notes WHERE body LIKE '%milk%';
                """),
        ]
    )

    static let finance = PracticeTemplate(
        id: "finance", name: "Personal Finance", summary: "Bank accounts, categories, income and expenses, and monthly budgets.",
        symbol: "dollarsign.circle.fill", tint: 0x30B158, tables: ["accounts", "categories", "transactions", "budgets"],
        script: """
            CREATE TABLE accounts (
                id INTEGER PRIMARY KEY,
                name TEXT NOT NULL,
                kind TEXT NOT NULL CHECK (kind IN ('checking', 'savings', 'credit_card', 'cash')),
                opening_balance REAL NOT NULL DEFAULT 0
            );
            CREATE TABLE categories (
                id INTEGER PRIMARY KEY,
                name TEXT NOT NULL UNIQUE,
                is_income INTEGER NOT NULL DEFAULT 0
            );
            CREATE TABLE transactions (
                id INTEGER PRIMARY KEY,
                account_id INTEGER NOT NULL REFERENCES accounts(id),
                category_id INTEGER NOT NULL REFERENCES categories(id),
                description TEXT NOT NULL,
                amount REAL NOT NULL,
                happened_on TEXT NOT NULL
            );
            CREATE TABLE budgets (
                id INTEGER PRIMARY KEY,
                category_id INTEGER NOT NULL REFERENCES categories(id),
                month TEXT NOT NULL,
                amount REAL NOT NULL,
                UNIQUE (category_id, month)
            );
            INSERT INTO accounts VALUES (1, 'Checking', 'checking', 1500), (2, 'Savings', 'savings', 5000), (3, 'Credit card', 'credit_card', 0), (4, 'Wallet', 'cash', 80);
            INSERT INTO categories VALUES (1, 'Salary', 1), (2, 'Freelance', 1), (3, 'Rent', 0), (4, 'Groceries', 0), (5, 'Restaurants', 0), (6, 'Transport', 0), (7, 'Subscriptions', 0), (8, 'Health', 0);
            INSERT INTO transactions VALUES
                (1, 1, 1, 'Monthly salary', 4200, '2026-09-05'), (2, 1, 3, 'Rent September', -1400, '2026-09-06'),
                (3, 3, 4, 'Supermarket', -310.45, '2026-09-08'), (4, 3, 5, 'Pizza night', -86.90, '2026-09-12'),
                (5, 4, 6, 'Bus card top-up', -50, '2026-09-13'), (6, 3, 7, 'Music streaming', -21.90, '2026-09-15'),
                (7, 1, 2, 'Website for a client', 900, '2026-09-20'), (8, 3, 8, 'Pharmacy', -64.30, '2026-09-22'),
                (9, 1, 1, 'Monthly salary', 4200, '2026-10-05'), (10, 1, 3, 'Rent October', -1400, '2026-10-06'),
                (11, 3, 4, 'Supermarket', -287.10, '2026-10-07'), (12, 3, 5, 'Sushi', -132.00, '2026-10-10'),
                (13, 4, 6, 'Taxi', -38.50, '2026-10-11'), (14, 3, 7, 'Music streaming', -21.90, '2026-10-15'),
                (15, 2, 2, 'Logo design', 450, '2026-10-16');
            INSERT INTO budgets VALUES (1, 4, '2026-10', 300), (2, 5, '2026-10', 150), (3, 6, '2026-10', 100), (4, 7, '2026-10', 30);
            """,
        examples: [
            .init(name: "Balance per account", sql: """
                SELECT a.name, a.opening_balance + COALESCE(SUM(t.amount), 0) AS balance
                FROM accounts a LEFT JOIN transactions t ON t.account_id = a.id
                GROUP BY a.id
                ORDER BY balance DESC;
                """),
            .init(name: "Spending by category", sql: """
                SELECT c.name AS category, -SUM(t.amount) AS spent
                FROM transactions t JOIN categories c ON c.id = t.category_id
                WHERE c.is_income = 0 AND t.happened_on LIKE '2026-10%'
                GROUP BY c.id
                ORDER BY spent DESC;
                """),
            .init(name: "Budget vs actual (October)", sql: """
                SELECT c.name AS category, b.amount AS budget,
                       COALESCE(-SUM(t.amount), 0) AS spent,
                       b.amount + COALESCE(SUM(t.amount), 0) AS left_over
                FROM budgets b
                JOIN categories c ON c.id = b.category_id
                LEFT JOIN transactions t ON t.category_id = b.category_id AND substr(t.happened_on, 1, 7) = b.month
                WHERE b.month = '2026-10'
                GROUP BY b.id;
                """),
        ]
    )

    static let tasks = PracticeTemplate(
        id: "tasks", name: "Tasks", summary: "Projects and to-dos with status, priority, due dates and assignees.",
        symbol: "checklist", tint: 0x0A84FF, tables: ["people", "projects", "tasks"],
        script: """
            CREATE TABLE people (
                id INTEGER PRIMARY KEY,
                name TEXT NOT NULL
            );
            CREATE TABLE projects (
                id INTEGER PRIMARY KEY,
                name TEXT NOT NULL,
                archived INTEGER NOT NULL DEFAULT 0
            );
            CREATE TABLE tasks (
                id INTEGER PRIMARY KEY,
                project_id INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
                assignee_id INTEGER REFERENCES people(id) ON DELETE SET NULL,
                title TEXT NOT NULL,
                status TEXT NOT NULL DEFAULT 'todo' CHECK (status IN ('todo', 'doing', 'done')),
                priority INTEGER NOT NULL DEFAULT 2 CHECK (priority BETWEEN 1 AND 3),
                due_on TEXT,
                done_at TEXT
            );
            INSERT INTO people VALUES (1, 'Ana'), (2, 'Bruno'), (3, 'Carla');
            INSERT INTO projects VALUES (1, 'Website redesign', 0), (2, 'Mobile app', 0), (3, 'Moving house', 0), (4, 'Old blog', 1);
            INSERT INTO tasks VALUES
                (1, 1, 1, 'Pick a colour palette', 'done', 2, '2026-10-05', '2026-10-04'),
                (2, 1, 2, 'Build the new homepage', 'doing', 1, '2026-10-20', NULL),
                (3, 1, 1, 'Write the About page', 'todo', 3, '2026-10-25', NULL),
                (4, 2, 3, 'Login screen', 'doing', 1, '2026-10-19', NULL),
                (5, 2, 3, 'Push notifications', 'todo', 2, '2026-11-02', NULL),
                (6, 2, NULL, 'App Store screenshots', 'todo', 3, NULL, NULL),
                (7, 3, 2, 'Book the moving truck', 'done', 1, '2026-10-10', '2026-10-09'),
                (8, 3, 1, 'Pack the kitchen', 'todo', 2, '2026-10-18', NULL),
                (9, 3, 2, 'Change address at the bank', 'todo', 2, '2026-10-30', NULL),
                (10, 4, 1, 'Export old posts', 'done', 3, NULL, '2026-03-01');
            """,
        examples: [
            .init(name: "Open tasks by due date", sql: """
                SELECT t.title, p.name AS project, pe.name AS assignee, t.priority, t.due_on
                FROM tasks t
                JOIN projects p ON p.id = t.project_id
                LEFT JOIN people pe ON pe.id = t.assignee_id
                WHERE t.status <> 'done' AND p.archived = 0
                ORDER BY t.due_on IS NULL, t.due_on, t.priority;
                """),
            .init(name: "Progress per project", sql: """
                SELECT p.name,
                       SUM(t.status = 'done') AS done,
                       COUNT(*) AS total,
                       ROUND(100.0 * SUM(t.status = 'done') / COUNT(*)) AS percent
                FROM projects p JOIN tasks t ON t.project_id = p.id
                GROUP BY p.id;
                """),
            .init(name: "Mark a task done", sql: """
                -- Change the id, run it, then open the tasks table to see the change.
                UPDATE tasks SET status = 'done', done_at = date('now') WHERE id = 8;
                """),
        ]
    )

    static let store = PracticeTemplate(
        id: "store", name: "Online Store", summary: "Customers, products, orders and order items: the classic e-commerce schema.",
        symbol: "cart.fill", tint: 0xFF6A00, tables: ["customers", "products", "orders", "order_items"],
        script: """
            CREATE TABLE customers (
                id INTEGER PRIMARY KEY,
                name TEXT NOT NULL,
                email TEXT NOT NULL UNIQUE,
                city TEXT
            );
            CREATE TABLE products (
                id INTEGER PRIMARY KEY,
                name TEXT NOT NULL,
                category TEXT NOT NULL,
                price REAL NOT NULL CHECK (price >= 0),
                stock INTEGER NOT NULL DEFAULT 0
            );
            CREATE TABLE orders (
                id INTEGER PRIMARY KEY,
                customer_id INTEGER NOT NULL REFERENCES customers(id),
                status TEXT NOT NULL CHECK (status IN ('pending', 'paid', 'shipped', 'canceled')),
                ordered_at TEXT NOT NULL
            );
            CREATE TABLE order_items (
                order_id INTEGER NOT NULL REFERENCES orders(id) ON DELETE CASCADE,
                product_id INTEGER NOT NULL REFERENCES products(id),
                quantity INTEGER NOT NULL CHECK (quantity > 0),
                unit_price REAL NOT NULL,
                PRIMARY KEY (order_id, product_id)
            );
            INSERT INTO customers VALUES
                (1, 'Ana Souza', 'ana@example.test', 'São Paulo'), (2, 'Bruno Lima', 'bruno@example.test', 'Lisboa'),
                (3, 'Carla Dias', 'carla@example.test', 'Recife'), (4, 'Diego Rocha', 'diego@example.test', 'Porto'),
                (5, 'Eva Martins', 'eva@example.test', 'Curitiba');
            INSERT INTO products VALUES
                (1, 'Coffee beans 1 kg', 'Coffee', 89.90, 40), (2, 'French press', 'Coffee', 149.00, 12),
                (3, 'Ceramic mug', 'Kitchen', 39.90, 100), (4, 'Notebook A5', 'Stationery', 24.50, 75),
                (5, 'Fountain pen', 'Stationery', 129.00, 8), (6, 'Desk lamp', 'Home', 219.00, 5);
            INSERT INTO orders VALUES
                (1, 1, 'shipped', '2026-09-28'), (2, 2, 'paid', '2026-10-02'), (3, 1, 'paid', '2026-10-09'),
                (4, 3, 'pending', '2026-10-15'), (5, 4, 'canceled', '2026-10-16'), (6, 5, 'shipped', '2026-10-17');
            INSERT INTO order_items VALUES
                (1, 1, 2, 89.90), (1, 3, 2, 39.90), (2, 2, 1, 149.00), (2, 1, 1, 89.90),
                (3, 4, 3, 24.50), (4, 6, 1, 219.00), (5, 5, 1, 129.00), (6, 3, 4, 39.90), (6, 4, 2, 24.50);
            """,
        examples: [
            .init(name: "Order totals", sql: """
                SELECT o.id, c.name AS customer, o.status, SUM(i.quantity * i.unit_price) AS total
                FROM orders o
                JOIN customers c ON c.id = o.customer_id
                JOIN order_items i ON i.order_id = o.id
                GROUP BY o.id
                ORDER BY o.ordered_at;
                """),
            .init(name: "Best-selling products", sql: """
                SELECT p.name, SUM(i.quantity) AS sold
                FROM order_items i
                JOIN products p ON p.id = i.product_id
                JOIN orders o ON o.id = i.order_id
                WHERE o.status <> 'canceled'
                GROUP BY p.id
                ORDER BY sold DESC;
                """),
            .init(name: "Low stock", sql: "SELECT name, stock FROM products WHERE stock < 10 ORDER BY stock;"),
        ]
    )

    static let blog = PracticeTemplate(
        id: "blog", name: "Blog", summary: "Authors, posts and comments, with drafts and published posts.",
        symbol: "text.bubble.fill", tint: 0xFF375F, tables: ["authors", "posts", "comments"],
        script: """
            CREATE TABLE authors (
                id INTEGER PRIMARY KEY,
                name TEXT NOT NULL,
                bio TEXT
            );
            CREATE TABLE posts (
                id INTEGER PRIMARY KEY,
                author_id INTEGER NOT NULL REFERENCES authors(id),
                title TEXT NOT NULL,
                slug TEXT NOT NULL UNIQUE,
                body TEXT NOT NULL,
                published_at TEXT
            );
            CREATE TABLE comments (
                id INTEGER PRIMARY KEY,
                post_id INTEGER NOT NULL REFERENCES posts(id) ON DELETE CASCADE,
                author_name TEXT NOT NULL,
                body TEXT NOT NULL,
                created_at TEXT NOT NULL
            );
            INSERT INTO authors VALUES (1, 'Ana Souza', 'Writes about coffee and code.'), (2, 'Bruno Lima', 'Travels and takes photos.');
            INSERT INTO posts VALUES
                (1, 1, 'My first SQL query', 'my-first-sql-query', 'SELECT is where it all starts…', '2026-09-01'),
                (2, 2, 'Three days in Lisbon', 'three-days-in-lisbon', 'Trams, pastéis de nata and hills.', '2026-09-14'),
                (3, 1, 'JOINs explained with coffee', 'joins-explained-with-coffee', 'Think of two tables as two cups…', '2026-10-03'),
                (4, 2, 'Packing light', 'packing-light', 'One backpack is enough.', NULL);
            INSERT INTO comments VALUES
                (1, 1, 'Carla', 'Great intro, thanks!', '2026-09-02 10:00'), (2, 1, 'Diego', 'Can you cover GROUP BY next?', '2026-09-03 12:30'),
                (3, 2, 'Eva', 'Lisbon is my favourite city.', '2026-09-15 08:15'), (4, 3, 'Felipe', 'The coffee analogy finally made it click.', '2026-10-04 19:45'),
                (5, 3, 'Carla', 'Saved for later.', '2026-10-05 09:00');
            """,
        examples: [
            .init(name: "Published posts with comment counts", sql: """
                SELECT p.title, a.name AS author, p.published_at, COUNT(c.id) AS comments
                FROM posts p
                JOIN authors a ON a.id = p.author_id
                LEFT JOIN comments c ON c.post_id = p.id
                WHERE p.published_at IS NOT NULL
                GROUP BY p.id
                ORDER BY p.published_at DESC;
                """),
            .init(name: "Drafts", sql: "SELECT title, slug FROM posts WHERE published_at IS NULL;"),
            .init(name: "Latest comments", sql: """
                SELECT c.author_name, c.body, p.title AS post
                FROM comments c JOIN posts p ON p.id = c.post_id
                ORDER BY c.created_at DESC
                LIMIT 5;
                """),
        ]
    )
}
