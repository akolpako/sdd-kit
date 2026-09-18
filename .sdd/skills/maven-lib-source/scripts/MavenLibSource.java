// MavenLibSource — what a Java source file declares, and the text of the methods
// it declares, taken from javac's own parse tree.
//
//   java MavenLibSource.java index  <file>
//   java MavenLibSource.java method <file> <name>
//
// index  prints "<line>  <declaration>" for every type, method, field and enum
//        constant, in source order, and for nothing a body holds.
// method prints the whole of every overload of that name, its javadoc and its
//        annotations included, blank-line separated. A constructor is asked for
//        by the name of the class that declares it.
//
// Exit: 0 ok | 1 no such method | 2 usage | 3 no javac in this runtime
//       4 the file did not parse
//
// It is a fallback that this replaces, not the other way round: the shell falls
// back to reading the text by hand when this cannot run — no JDK, a runtime
// older than the source, a file that is not Java. So every failure here is a
// non-zero exit and an empty stdout, never a partial answer.

import com.sun.source.tree.*;
import com.sun.source.util.*;

import javax.tools.Diagnostic;
import javax.tools.DiagnosticCollector;
import javax.tools.JavaCompiler;
import javax.tools.JavaFileObject;
import javax.tools.StandardJavaFileManager;
import javax.tools.ToolProvider;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.Deque;
import java.util.List;

public class MavenLibSource {

    public static void main(String[] args) {
        int rc;
        try {
            rc = run(args);
        } catch (Throwable t) {
            System.err.println("MavenLibSource: " + t);
            rc = 4;
        }
        System.exit(rc);
    }

    private static int run(String[] args) throws Exception {
        if (args.length < 2 || (!args[0].equals("index") && !args[0].equals("method"))
                || (args[0].equals("method") && args.length < 3)) {
            System.err.println("usage: MavenLibSource index <file> | MavenLibSource method <file> <name>");
            return 2;
        }
        JavaCompiler compiler = ToolProvider.getSystemJavaCompiler();
        if (compiler == null) {
            System.err.println("MavenLibSource: this runtime carries no compiler, so nothing can be parsed.");
            return 3;
        }
        DiagnosticCollector<JavaFileObject> problems = new DiagnosticCollector<>();
        try (StandardJavaFileManager files = compiler.getStandardFileManager(problems, null, null)) {
            JavacTask task = (JavacTask) compiler.getTask(null, files, problems,
                    List.of("-proc:none"), null, files.getJavaFileObjects(args[1]));
            List<CompilationUnitTree> units = new ArrayList<>();
            task.parse().forEach(units::add);

            // A recovered parse is a partial tree, and a partial tree is an index
            // that is quietly missing declarations. Saying so is the whole point.
            for (Diagnostic<? extends JavaFileObject> d : problems.getDiagnostics()) {
                if (d.getKind() == Diagnostic.Kind.ERROR) {
                    System.err.println("MavenLibSource: " + args[1] + " did not parse: " + d.getMessage(null));
                    return 4;
                }
            }
            if (units.isEmpty()) return 4;

            MavenLibSource reader = new MavenLibSource(units.get(0), Trees.instance(task));
            if (args[0].equals("index")) {
                reader.index();
                System.out.print(reader.out);
                return 0;
            }
            reader.method(args[2]);
            System.out.print(reader.out);
            return reader.out.length() == 0 ? 1 : 0;
        }
    }

    private final CompilationUnitTree unit;
    private final SourcePositions positions;
    private final LineMap lineMap;
    private final String source;
    private final StringBuilder out = new StringBuilder();

    private MavenLibSource(CompilationUnitTree unit, Trees trees) throws Exception {
        this.unit = unit;
        this.positions = trees.getSourcePositions();
        this.lineMap = unit.getLineMap();
        this.source = unit.getSourceFile().getCharContent(true).toString();
    }

    // --- positions ----------------------------------------------------------

    private int start(Tree t) { return (int) positions.getStartPosition(unit, t); }

    private int end(Tree t) { return (int) positions.getEndPosition(unit, t); }

    /**
     * The brace that opens a type body. A "{" that is not inside a parenthesis,
     * a string or a comment can be nothing else: an annotation's array sits
     * inside the parentheses of the annotation, and a header holds no other
     * braces.
     */
    private int bodyBrace(int from) {
        int depth = 0;
        for (int i = Math.max(from, 0); i < source.length(); i++) {
            char c = source.charAt(i);
            if (c == '/' && i + 1 < source.length()) {
                char n = source.charAt(i + 1);
                if (n == '/') { while (i < source.length() && source.charAt(i) != '\n') i++; continue; }
                if (n == '*') { i = source.indexOf("*/", i + 2); if (i < 0) return -1; i++; continue; }
            }
            if (c == '"' || c == '\'') { i = endOfLiteral(i); if (i < 0) return -1; continue; }
            if (c == '(' || c == '[') depth++;
            else if (c == ')' || c == ']') depth--;
            else if (c == '{' && depth <= 0) return i;
        }
        return -1;
    }

    /** The index of the closing quote of the literal that opens at {@code i}. */
    private int endOfLiteral(int i) {
        char quote = source.charAt(i);
        if (quote == '"' && source.startsWith("\"\"\"", i)) {
            int close = source.indexOf("\"\"\"", i + 3);
            return close < 0 ? -1 : close + 2;
        }
        for (int j = i + 1; j < source.length(); j++) {
            char c = source.charAt(j);
            if (c == '\\') { j++; continue; }
            if (c == quote) return j;
            if (c == '\n') return j;                 // an unterminated literal
        }
        return -1;
    }

    /**
     * Where the declaration itself begins: past the annotations that lead it,
     * but never past a modifier, so "public @Nullable String f()" keeps its
     * "public".
     */
    private int afterLeadingAnnotations(int from) {
        int i = from;
        while (i < source.length()) {
            i = skipBlanks(i);
            if (i >= source.length() || source.charAt(i) != '@') return i;
            int j = i + 1;
            j = skipBlanks(j);
            int nameAt = j;
            while (j < source.length() && (Character.isJavaIdentifierPart(source.charAt(j)) || source.charAt(j) == '.')) j++;
            // "@interface" declares a type; it does not annotate one.
            if (source.startsWith("interface", nameAt) && j == nameAt + "interface".length()) return i;
            int k = skipBlanks(j);
            if (k < source.length() && source.charAt(k) == '(') {
                int depth = 0;
                while (k < source.length()) {
                    char c = source.charAt(k);
                    if (c == '"' || c == '\'') { k = endOfLiteral(k); if (k < 0) return i; }
                    else if (c == '(') depth++;
                    else if (c == ')' && --depth == 0) { k++; break; }
                    k++;
                }
                j = k;
            }
            i = j;
        }
        return i;
    }

    private int skipBlanks(int i) {
        while (i < source.length()) {
            char c = source.charAt(i);
            if (Character.isWhitespace(c)) { i++; continue; }
            if (c == '/' && i + 1 < source.length()) {
                char n = source.charAt(i + 1);
                if (n == '/') { while (i < source.length() && source.charAt(i) != '\n') i++; continue; }
                if (n == '*') { int e = source.indexOf("*/", i + 2); if (e < 0) return source.length(); i = e + 2; continue; }
            }
            return i;
        }
        return i;
    }

    // --- the index ----------------------------------------------------------

    private void index() {
        Deque<ClassTree> enclosing = new ArrayDeque<>();
        new TreeScanner<Void, Void>() {

            @Override
            public Void visitClass(ClassTree t, Void p) {
                int from = afterLeadingAnnotations(start(t));
                int brace = bodyBrace(from);
                emit(from, brace < 0 ? end(t) : brace);
                enclosing.push(t);
                for (Tree member : t.getMembers()) {
                    // A record's components stand in its header, and the header
                    // has already been printed.
                    if (brace > 0 && start(member) >= 0 && start(member) < brace) continue;
                    scan(member, p);
                }
                enclosing.pop();
                return null;
            }

            @Override
            public Void visitMethod(MethodTree t, Void p) {
                if (isGenerated(t)) return null;
                int from = afterLeadingAnnotations(start(t));
                int to = t.getBody() != null ? start(t.getBody()) : end(t);
                emit(from, to);
                return null;                                   // never the body
            }

            @Override
            public Void visitVariable(VariableTree t, Void p) {
                if (isGenerated(t)) return null;
                int from = afterLeadingAnnotations(start(t));
                int to = t.getInitializer() != null ? start(t.getInitializer()) : end(t);
                ClassTree owner = enclosing.peek();
                if (owner != null && owner.getKind() == Tree.Kind.ENUM && isEnumConstant(t)) {
                    // "OPEN" and "OPEN(1)" both, and neither the type javac
                    // filled in nor the comma that follows.
                    to = t.getInitializer() != null ? end(t) : end(t);
                }
                emit(from, to);
                return null;                              // never the initialiser
            }

            @Override
            public Void visitBlock(BlockTree t, Void p) {
                return null;             // an initialiser block declares nothing
            }
        }.scan(unit, null);
    }

    /**
     * An enum constant is a field javac wrote the type of: the type it carries
     * is not in the source, so it starts where the name does.
     */
    private boolean isEnumConstant(VariableTree t) {
        Tree type = t.getType();
        if (type == null) return false;
        int typeStart = start(type);
        return typeStart < 0 || typeStart >= start(t);
    }

    /** Members javac made up carry no position in the file that was read. */
    private boolean isGenerated(Tree t) {
        return start(t) < 0;
    }

    private void emit(int from, int to) {
        if (from < 0) return;
        if (to <= from || to > source.length()) to = Math.min(source.length(), from + 1);
        String text = strip(source.substring(from, to));
        if (text.isEmpty()) return;
        out.append(String.format("%6d  %s%n", lineMap.getLineNumber(from), text));
    }

    /** The declaration on one line: no comments, no trailing "=", "{" or ";". */
    private String strip(String text) {
        StringBuilder b = new StringBuilder(text.length());
        for (int i = 0; i < text.length(); i++) {
            char c = text.charAt(i);
            if (c == '/' && i + 1 < text.length()) {
                char n = text.charAt(i + 1);
                if (n == '/') { while (i < text.length() && text.charAt(i) != '\n') i++; b.append(' '); continue; }
                if (n == '*') { int e = text.indexOf("*/", i + 2); i = e < 0 ? text.length() : e + 1; b.append(' '); continue; }
            }
            b.append(c);
        }
        String one = b.toString().replaceAll("\\s+", " ").trim();
        while (!one.isEmpty()) {
            char last = one.charAt(one.length() - 1);
            if (last == '=' || last == '{' || last == ';' || last == ',' || Character.isWhitespace(last)) {
                one = one.substring(0, one.length() - 1).stripTrailing();
            } else {
                break;
            }
        }
        return one;
    }

    // --- one method ---------------------------------------------------------

    private void method(String name) {
        Deque<ClassTree> enclosing = new ArrayDeque<>();
        new TreeScanner<Void, Void>() {

            @Override
            public Void visitClass(ClassTree t, Void p) {
                enclosing.push(t);
                super.visitClass(t, p);
                enclosing.pop();
                return null;
            }

            @Override
            public Void visitMethod(MethodTree t, Void p) {
                if (isGenerated(t)) return null;
                ClassTree owner = enclosing.peek();
                String declared = t.getName().toString();
                boolean hit = declared.equals(name)
                        || (declared.equals("<init>") && owner != null
                            && owner.getSimpleName().toString().equals(name));
                if (hit) {
                    if (out.length() > 0) out.append(System.lineSeparator());
                    out.append(wholeLines(withDocComment(start(t)), end(t)));
                }
                return null;
            }

            @Override
            public Void visitBlock(BlockTree t, Void p) {
                return null;         // a method declared inside a body is local
            }
        }.scan(unit, null);
    }

    /** The javadoc and the line comments that sit directly above a declaration. */
    private int withDocComment(int from) {
        int i = from;
        while (true) {
            int j = i - 1;
            while (j >= 0 && Character.isWhitespace(source.charAt(j))) j--;
            if (j >= 1 && source.charAt(j) == '/' && source.charAt(j - 1) == '*') {
                int open = source.lastIndexOf("/*", j - 1);
                if (open < 0) return i;
                i = open;
                continue;
            }
            int lineStart = source.lastIndexOf('\n', Math.max(j, 0)) + 1;
            if (j >= lineStart + 1 && source.startsWith("//", lineStart)
                    && source.substring(lineStart, j + 1).trim().startsWith("//")) {
                i = lineStart;
                continue;
            }
            return i;
        }
    }

    /** The range grown out to whole lines, so the indentation comes with it. */
    private String wholeLines(int from, int to) {
        int a = source.lastIndexOf('\n', Math.max(from - 1, 0));
        a = a < 0 ? 0 : a + 1;
        if (from == 0) a = 0;
        int b = source.indexOf('\n', Math.min(to, source.length() - 1));
        b = b < 0 ? source.length() : b;
        return source.substring(a, b) + System.lineSeparator();
    }
}
