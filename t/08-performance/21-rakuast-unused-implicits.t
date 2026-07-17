use lib <t/packages/Test-Helpers>;
use Test::Helpers::QAST;
use Test;
use QAST:from<NQP>;
use nqp;
plan 11;

# A routine declares fresh $_ and $¢ containers it usually never uses,
# and a block binds its topic from the enclosing one. When nothing in
# the scope, and nothing reaching lexicals by name at run time, uses
# such an implicit, its declaration is not emitted, which saves a
# container clone per call.

sub qast-var-decl (Mu $qast, Str:D $name, Str:D $decl --> Bool:D) {
    if nqp::istype($qast, QAST::Var) && $qast.name eq $name && $qast.decl eq $decl {
        return True;
    }
    if qast-descendable $qast {
        for $qast.list {
            qast-var-decl $_, $name, $decl and return True;
        }
    }
    False
}

qast-is 'sub f($a) { $a + $a }; say f(1)', :full, -> \v {
    not qast-var-decl(v, '$_', 'contvar')
}, 'a sub that never touches the topic declares no fresh $_';

# The kept-shape and cursor assertions are this frontend's: the legacy
# optimizer lowers a used topic to a local rather than keeping the
# contvar, and gates $¢ on the scope making no calls at all, which an
# operator call already defeats.
if nqp::ifnull(nqp::gethllsym('Raku', 'COMPILER-FRONTEND'), '') eq 'rakuast' {
    qast-is 'sub f($a) { $_ = $a; $_ + 1 }; say f(1)', :full, -> \v {
        qast-var-decl(v, '$_', 'contvar')
    }, 'a sub that assigns the topic keeps its fresh $_';

    qast-is 'sub f($a) { $a ~~ Int }; say f(1)', :full, -> \v {
        qast-var-decl(v, '$_', 'contvar')
    }, 'a smartmatch reaches the topic by name, so the fresh $_ stays';

    qast-is 'sub f($a) { $a + $a }; say f(1)', :full, -> \v {
        not qast-var-decl(v, '$¢', 'contvar')
    }, 'a sub with no regex declares no fresh $¢';
}
else {
    skip 'shapes specific to the RakuAST frontend', 3;
}

# Behavior stays identical.

{
    sub topical() { $_ = 5; $_ + 1 }
    is topical(), 6, 'assigning and reading the topic in a sub behaves unchanged';
}

{
    $_ = 42;
    sub fresh() { $_ }
    ok !fresh().defined, 'a sub sees its own fresh topic, not the enclosing one';
}

{
    $_ = 1;
    given 2 { is $_, 2, 'given topicalizes' }
    is $_, 1, 'the enclosing topic survives a given';
}

{
    my @r;
    for 1..3 { @r.push($_) }
    is @r.join(','), '1,2,3', 'a for loop binds its topic per iteration';
}

{
    sub matcher($x) { $x ~~ Int ?? 'int' !! 'other' }
    is matcher(1), 'int', 'smartmatch in a sub with a kept topic works';
}

{
    my $seen;
    sub capturer() { my $c = { $seen = $_ }; $c(7) }
    capturer();
    is $seen, 7, 'a closure taking the topic as its argument still receives it';
}
