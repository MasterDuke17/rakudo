# Escape analysis for lexical-to-local lowering. Walks a checked and
# optimized compilation unit and decides, per `my` declaration, whether
# every access is confined to the frame that declares it. A confined
# declaration is marked so QAST emission can use a frame-local register
# slot instead of a by-name lexical entry. The walk mirrors the frame
# structure QAST emission produces: every node that creates a block (a
# lexical scope, or an expression carrying thunks) is a frame boundary.

# Per-frame bookkeeping made while the walk is inside that frame.
class RakuAST::IMPL::VarLoweringFrame {
    has RakuAST::Node $!node;
    has int $!is-scope;
    has int $!poisoned;
    has Mu $!candidates;
    has Mu $!candidate-ids;
    has Mu $!candidate-names;

    method new(RakuAST::Node $node, int $is-scope) {
        my $obj := nqp::create(self);
        nqp::bindattr($obj, RakuAST::IMPL::VarLoweringFrame, '$!node', $node);
        nqp::bindattr_i($obj, RakuAST::IMPL::VarLoweringFrame, '$!is-scope', $is-scope);
        nqp::bindattr($obj, RakuAST::IMPL::VarLoweringFrame, '$!candidates', []);
        nqp::bindattr($obj, RakuAST::IMPL::VarLoweringFrame, '$!candidate-ids', nqp::hash());
        nqp::bindattr($obj, RakuAST::IMPL::VarLoweringFrame, '$!candidate-names', nqp::hash());
        $obj
    }

    method node() { $!node }
    method is-scope() { $!is-scope }
    method poison() {
        nqp::bindattr_i(self, RakuAST::IMPL::VarLoweringFrame, '$!poisoned', 1);
        Nil
    }
    method is-poisoned() { $!poisoned }

    method register(Mu $decl, str $declined) {
        my $record := nqp::hash('decl', $decl, 'declined', $declined);
        # Redeclarations of one name in one scope share a runtime symbol,
        # so neither copy can own a private register slot.
        my str $name := $decl.lexical-name;
        my $clash := nqp::atkey($!candidate-names, $name);
        if nqp::isnull($clash) {
            nqp::bindkey($!candidate-names, $name, $record);
        }
        else {
            nqp::bindkey($clash, 'declined', 'duplicate')
                unless nqp::atkey($clash, 'declined');
            nqp::bindkey($record, 'declined', 'duplicate')
                unless $declined;
        }
        nqp::push($!candidates, $record);
        nqp::bindkey($!candidate-ids, ~nqp::objectid($decl), $record);
        $record
    }

    # An extra identity a use-site's resolution may carry for this
    # candidate, such as the parameter target wrapping a declaration.
    method alias(str $id, Mu $record) {
        nqp::bindkey($!candidate-ids, $id, $record);
        Nil
    }

    method record-for-id(str $id) {
        nqp::atkey($!candidate-ids, $id)
    }

    method candidates() { $!candidates }
}

# Drives the analysis. One instance analyzes one compilation unit.
class RakuAST::IMPL::VarLowering {
    has Mu $!frames;
    has Mu $!sentinel;
    has int $!debug;
    has int $!begin-context;

    method analyze-compunit(RakuAST::CompUnit $compunit, RakuAST::Resolver $resolver, :$interactive?) {
        # Escape hatch while the lowering is young: skip the analysis
        # entirely, leaving every lexical emitted by name.
        return Nil if nqp::atkey(nqp::getenvhash(), 'RAKUDO_NO_LEX2LOCAL');

        my $analyzer := nqp::create(self);
        nqp::bindattr($analyzer, RakuAST::IMPL::VarLowering, '$!frames', []);
        nqp::bindattr_i($analyzer, RakuAST::IMPL::VarLowering, '$!debug',
            nqp::atkey(nqp::getenvhash(), 'RAKUDO_LOWERING_DEBUG') ?? 1 !! 0);

        # The sentinel type that stands in for a lowered lexical's
        # by-name symbol. Without it (very early bootstrap) nothing is
        # marked, since the emitted placeholder could not be produced.
        my $sentinel := nqp::null;
        my $sentinel-name := RakuAST::Name.from-identifier-parts(
            'Rakudo', 'Internals', 'LoweredAwayLexical');
        my $found := $resolver.resolve-name-constant-in-setting($sentinel-name);
        $found := $resolver.resolve-name-constant($sentinel-name)
            unless nqp::isconcrete($found);
        $sentinel := $found.compile-time-value
            if nqp::isconcrete($found) && nqp::can($found, 'compile-time-value');
        nqp::bindattr($analyzer, RakuAST::IMPL::VarLowering, '$!sentinel', $sentinel);

        # The mainline Block is an empty shell for the mainline code
        # object; the compilation unit's statements live in the statement
        # list, which QAST emission places directly in the mainline frame.
        # So the compilation unit and the mainline share one frame here,
        # and the shell is skipped to visit each node exactly once.
        my $mainline := $compunit.mainline;
        $analyzer.IMPL-ENTER($compunit, 1);
        # Each interactive (REPL) line must leave its lexicals reachable
        # by name for the lines compiled after it.
        $analyzer.IMPL-POISON-ALL() if $interactive;
        $compunit.visit-children(-> $child {
            $analyzer.IMPL-WALK($child) unless nqp::eqaddr($child, $mainline);
        });
        $analyzer.IMPL-LEAVE();
        Nil
    }

    method IMPL-WALK(RakuAST::Node $node) {
        # Trait arguments, type parameterizations, and constant
        # initializers are evaluated at BEGIN time by dynamically
        # compiled code that reaches lexicals by name, which neither the
        # frame nesting nor the resolutions here can show. Every use in
        # such a subtree escapes.
        my int $begin-entered;
        if nqp::istype($node, RakuAST::Trait)
            || nqp::istype($node, RakuAST::Type::Parameterized)
            || nqp::istype($node, RakuAST::VarDeclaration::Constant) {
            nqp::bindattr_i(self, RakuAST::IMPL::VarLowering, '$!begin-context',
                $!begin-context + 1);
            $begin-entered := 1;
        }
        if $begin-entered {
            self.IMPL-WALK-INNER($node);
            nqp::bindattr_i(self, RakuAST::IMPL::VarLowering, '$!begin-context',
                $!begin-context - 1);
            return Nil;
        }
        self.IMPL-WALK-INNER($node)
    }

    method IMPL-WALK-INNER(RakuAST::Node $node) {
        # A variable declaration belongs to the enclosing scope's frame,
        # not to any frame the node itself creates. A parameter's uses
        # resolve to the target node while emission delegates to the
        # declaration it wraps, so the target registers the declaration
        # under both identities, and the wrapped declaration itself is
        # skipped when the walk reaches it as a child.
        if nqp::istype($node, RakuAST::ParameterTarget::Var) {
            my $decl := $node.declaration;
            self.IMPL-REGISTER-DECL($decl, ~nqp::objectid($node))
                if nqp::isconcrete($decl)
                && nqp::istype($decl, RakuAST::VarDeclaration::Simple);
        }
        elsif nqp::istype($node, RakuAST::VarDeclaration::Simple) {
            self.IMPL-REGISTER-DECL($node)
                unless nqp::getattr($node, RakuAST::VarDeclaration::Simple, '$!is-parameter');
        }

        # A list declaration bound with := goes through the runtime
        # signature binder, which writes into the frame's lexicals by
        # name.
        if nqp::istype($node, RakuAST::VarDeclaration::Signature)
            && nqp::isconcrete($node.initializer)
            && $node.initializer.is-binding {
            self.IMPL-POISON-CURRENT-SCOPE();
        }

        # Feed stages are emitted inside blocks the tree does not show,
        # so anything a stage references stays a by-name lexical.
        if nqp::istype($node, RakuAST::ApplyListInfix)
            && nqp::istype($node.infix, RakuAST::Feed) {
            $node.visit-children(-> $child {
                self.IMPL-ENTER($child, 0);
                self.IMPL-WALK($child);
                self.IMPL-LEAVE();
            });
            return Nil;
        }

        # An nqp::handle handler is code-generated in an implicit block
        # of its own, so a lexical referenced from a handler must stay
        # addressable by name. The protected expression, the first
        # argument, runs in the current frame.
        if nqp::istype($node, RakuAST::Nqp)
            && ($node.op eq 'handle' || $node.op eq 'handlepayload') {
            my int $first := 1;
            $node.visit-children(-> $child {
                if $first {
                    $first := 0;
                    self.IMPL-WALK($child);
                }
                else {
                    self.IMPL-ENTER($child, 0);
                    self.IMPL-WALK($child);
                    self.IMPL-LEAVE();
                }
            });
            return Nil;
        }

        # A loop statement modifier's thunk wraps the statement
        # expression, and a condition modifier's test is compiled inside
        # that same thunk, while the loop source stays outside. Mirror
        # that frame placement rather than walking the modifiers in the
        # statement's own frame.
        if nqp::istype($node, RakuAST::Statement::Expression)
            && nqp::isconcrete($node.loop-modifier) {
            my $expression := $node.expression;
            if nqp::istype($expression, RakuAST::Expression) && $expression.creates-block {
                self.IMPL-ENTER($node, 0);
                self.IMPL-WALK($expression);
                self.IMPL-WALK($node.condition-modifier)
                    if nqp::isconcrete($node.condition-modifier);
                self.IMPL-LEAVE();
                self.IMPL-WALK($node.loop-modifier);
                $node.visit-labels(-> $label { self.IMPL-WALK($label) });
                return Nil;
            }
        }

        my int $pushed;
        if nqp::istype($node, RakuAST::MayCreateBlock) && $node.creates-block {
            self.IMPL-ENTER($node, nqp::istype($node, RakuAST::LexicalScope) ?? 1 !! 0);
            $pushed := 1;
            # A signature that needs the runtime binder binds by name
            # into the frame, so its lexicals must stay addressable.
            nqp::atpos($!frames, nqp::elems($!frames) - 1).poison()
                if nqp::istype($node, RakuAST::Code) && $node.custom-args;
        }

        self.IMPL-REGISTER-USE($node)
            if nqp::istype($node, RakuAST::Lookup) && $node.is-resolved;
        self.IMPL-CHECK-POISON($node);

        $node.visit-children(-> $child { self.IMPL-WALK($child) });

        self.IMPL-LEAVE() if $pushed;
        Nil
    }

    method IMPL-ENTER(RakuAST::Node $node, int $is-scope) {
        nqp::push($!frames, RakuAST::IMPL::VarLoweringFrame.new($node, $is-scope));
        Nil
    }

    method IMPL-LEAVE() {
        my $frame := nqp::pop($!frames);
        self.IMPL-DECIDE($frame) if $frame.is-scope;
        Nil
    }

    # Register a `my` declaration with the frame of its declaring scope,
    # along with any reason it must stay a lexical that is knowable from
    # the declaration alone.
    method IMPL-REGISTER-DECL(RakuAST::VarDeclaration::Simple $decl, str $alias-id?) {
        return Nil unless $decl.scope eq 'my';
        # An anonymous declaration has no name to look up, and nothing to
        # gain from this analysis until lowering handles it directly.
        return Nil if nqp::istype($decl, RakuAST::VarDeclaration::Anonymous);

        my int $i := nqp::elems($!frames);
        my $scope-frame;
        my int $scope-index := -1;
        while --$i >= 0 {
            my $frame := nqp::atpos($!frames, $i);
            if $frame.is-scope {
                $scope-frame := $frame;
                $scope-index := $i;
                last;
            }
        }
        return Nil if $scope-index < 0;

        my str $declined := '';
        my str $sigil := $decl.sigil;
        if $decl.twigil ne '' {
            $declined := 'twigil';
        }
        elsif $decl.forced-dynamic {
            $declined := 'dynamic';
        }
        elsif nqp::isconcrete($decl.container-descriptor)
            && $decl.container-descriptor.dynamic {
            # An `is dynamic` trait reaches the descriptor by mutation,
            # not through the declaration's own attributes.
            $declined := 'dynamic';
        }
        elsif $sigil ne '$' && $sigil ne '@' && $sigil ne '%' {
            # A callable is looked up by name as the callee of emitted
            # call ops, so a `&`-sigiled lexical must keep its symbol.
            $declined := 'callable';
        }
        elsif !nqp::iscclass(nqp::const::CCLASS_ALPHABETIC,
                $decl.desigilname.canonicalize, 0) {
            $declined := 'name';
        }
        elsif nqp::isconcrete($decl.shape) {
            $declined := 'shaped';
        }
        elsif self.IMPL-HAS-WILL-TRAIT($decl) {
            # A will phaser looks its variable up by name in the calling
            # frame at run time (Variable.willdo).
            $declined := 'will';
        }
        elsif $scope-index != nqp::elems($!frames) - 1 || $decl.creates-block {
            # The declaration is emitted under a thunk of its scope, so
            # its accesses cross a frame boundary the scope nesting does
            # not show.
            $declined := 'thunked';
        }
        my $record := $scope-frame.register($decl, $declined);
        $scope-frame.alias($alias-id, $record) if $alias-id;
        Nil
    }

    method IMPL-HAS-WILL-TRAIT(Mu $decl) {
        for $decl.IMPL-UNWRAP-LIST($decl.traits) {
            return 1 if nqp::istype($_, RakuAST::Trait::Will);
        }
        0
    }

    # A resolved lookup whose resolution is a tracked declaration marks
    # that declaration as captured when the lookup lives in any frame
    # other than the declaring one.
    method IMPL-REGISTER-USE(RakuAST::Node $node) {
        my str $id := ~nqp::objectid($node.resolution);
        my int $top := nqp::elems($!frames) - 1;
        my int $i := $top + 1;
        while --$i >= 0 {
            my $record := nqp::atpos($!frames, $i).record-for-id($id);
            unless nqp::isnull($record) {
                if $!begin-context {
                    nqp::bindkey($record, 'captured', 1);
                }
                elsif $i != $top {
                    nqp::bindkey($record, 'captured', 1);
                }
                return Nil;
            }
        }
        Nil
    }

    # Constructs that can reach lexicals by name at runtime. Any of them
    # poisons every frame the walk is currently inside: the lexicals of
    # those frames must stay addressable by name.
    method IMPL-CHECK-POISON(RakuAST::Node $node) {
        my constant POISON-CALLS := nqp::hash(
            'EVAL', 1, 'EVALFILE', 1,
            'callwith', 1, 'callsame', 1,
            'nextwith', 1, 'nextsame', 1,
            'samewith', 1,
            'throws-like', 1, 'repl', 1,
        );
        my constant POISON-VARS := nqp::hash(
            '&EVAL', 1, '&EVALFILE', 1,
            '&callwith', 1, '&callsame', 1,
            '&nextwith', 1, '&nextsame', 1,
            '&samewith', 1,
            '&throws-like', 1, '&repl', 1,
        );

        if nqp::istype($node, RakuAST::Call::Name) {
            my $name := $node.name;
            if $name.is-pseudo-package || $name.is-indirect-lookup
                || nqp::existskey(POISON-CALLS, $name.canonicalize) {
                self.IMPL-POISON-ALL();
            }
        }
        elsif nqp::istype($node, RakuAST::Var::Lexical) {
            if $node.desigilname.is-indirect-lookup
                || nqp::existskey(POISON-VARS, $node.name) {
                self.IMPL-POISON-ALL();
            }
        }
        elsif nqp::istype($node, RakuAST::Call::Method) {
            # A method named EVAL reaches enclosing lexicals the same way
            # the sub form does, for example a string or AST's .EVAL.
            my $name := $node.name;
            if nqp::istype($name, RakuAST::Name)
                && !$name.is-indirect-lookup
                && nqp::existskey(POISON-CALLS, $name.canonicalize) {
                self.IMPL-POISON-ALL();
            }
        }
        elsif nqp::istype($node, RakuAST::Var::Package)
            || nqp::istype($node, RakuAST::Term::Name)
            || nqp::istype($node, RakuAST::Type::Simple) {
            my $name := $node.name;
            if nqp::istype($name, RakuAST::Name)
                && ($name.is-pseudo-package || $name.is-indirect-lookup) {
                self.IMPL-POISON-ALL();
            }
        }
        elsif nqp::istype($node, RakuAST::QuotedRegex)
            || nqp::istype($node, RakuAST::RegexDeclaration)
            || nqp::istype($node, RakuAST::Substitution)
            || nqp::istype($node, RakuAST::Transliteration) {
            # Regex code reaches lexicals of its enclosing frames late,
            # through the cursor, not through resolved lookups this walk
            # can see. Substitutions and transliterations carry regex
            # and replacement code the same way.
            self.IMPL-POISON-ALL();
        }
        Nil
    }

    # This code runs where the NQP setting's IO subs are not reachable,
    # so stderr output is spelled out in ops, including the byte buffer
    # type to encode into.
    method IMPL-NOTE(str $message) {
        my $u8 := nqp::newtype(nqp::knowhow(), 'P6int');
        nqp::composetype($u8, nqp::hash('integer', nqp::hash('unsigned', 1, 'bits', 8)));
        my $buf-type := nqp::newtype(nqp::knowhow(), 'VMArray');
        nqp::composetype($buf-type, nqp::hash('array', nqp::hash('type', $u8)));
        nqp::writefh(nqp::getstderr(),
            nqp::encode($message ~ "\n", 'utf8', nqp::create($buf-type)));
        Nil
    }

    method IMPL-POISON-ALL() {
        my int $i := nqp::elems($!frames);
        while --$i >= 0 {
            nqp::atpos($!frames, $i).poison();
        }
        Nil
    }

    method IMPL-POISON-CURRENT-SCOPE() {
        my int $i := nqp::elems($!frames);
        while --$i >= 0 {
            my $frame := nqp::atpos($!frames, $i);
            if $frame.is-scope {
                $frame.poison();
                last;
            }
        }
        Nil
    }

    method IMPL-DECIDE(Mu $frame) {
        my $candidates := $frame.candidates;
        return Nil unless nqp::elems($candidates);
        my int $poisoned := $frame.is-poisoned;
        for $candidates -> $record {
            my $decl := nqp::atkey($record, 'decl');
            my str $declined := nqp::atkey($record, 'declined');
            if $declined eq '' && $poisoned {
                $declined := 'poisoned';
            }
            if $declined eq '' && nqp::existskey($record, 'captured') {
                $declined := 'captured';
            }
            if $declined eq '' {
                $decl.IMPL-SET-LOWERED-TO-LOCAL($!sentinel);
            }
            if $!debug {
                my str $where := $frame.node.HOW.name($frame.node);
                self.IMPL-NOTE($declined eq ''
                    ?? "lex2local: lower '" ~ $decl.lexical-name ~ "' in " ~ $where
                    !! "lex2local: keep '" ~ $decl.lexical-name ~ "' in "
                        ~ $where ~ " (" ~ $declined ~ ")");
            }
        }
        Nil
    }
}
