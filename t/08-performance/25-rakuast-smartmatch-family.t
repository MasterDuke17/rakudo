use lib <t/packages/Test-Helpers>;
use Test::Helpers::QAST;
use Test;
use QAST:from<NQP>;
use nqp;
plan 19;

# The helper's walk does not descend a ParamTypeCheck, and a local name
# identifies the unfolded junction more precisely than any op, so these
# walk every child list themselves.

sub qast-deep-contains-op (Mu $qast, Str:D $name --> Bool:D) {
    if nqp::istype($qast, QAST::Op) && $qast.op eq $name {
        return True;
    }
    for (try $qast.list) // () {
        return True if nqp::istype($_, QAST::Node) && qast-deep-contains-op($_, $name);
    }
    False
}

sub qast-contains-unfold-local (Mu $qast --> Bool:D) {
    if nqp::istype($qast, QAST::Var) && $qast.name.starts-with('junction_unfold') {
        return True;
    }
    for (try $qast.list) // () {
        return True if nqp::istype($_, QAST::Node) && qast-contains-unfold-local($_);
    }
    False
}

# The legacy frontend reduces through its own QAST optimizer, so the
# shapes here are this frontend's.
if nqp::ifnull(nqp::gethllsym('Raku', 'COMPILER-FRONTEND'), '') eq 'rakuast' {
    qast-is 'my Int $x; my $r = $x ~~ Int', :full, -> \v {
        not qast-contains-op(v, 'istype')
    }, 'a typematch guaranteed by the declared type folds away its check';

    qast-is 'my $x = 5; my $r = $x ~~ 42', :full, -> \v {
        not qast-contains-call(v, '&infix:<~~>')
    }, 'a literal matcher compiles without the smartmatch dispatch';

    qast-is 'my $x = 5; my $r = $x ~~ :is-prime', :full, -> \v {
        not qast-contains-call(v, '&infix:<~~>')
    }, 'a Pair matcher compiles without the smartmatch dispatch';

    qast-is 'my $x = 2; if $x == 1|2|3 { say 1 }', :full, -> \v {
        qast-contains-unfold-local(v)
    }, 'a junction comparison in boolean position unfolds to a short-circuit chain';

    qast-is 'my $x = 2; my $r = $x == 1|2', :full, -> \v {
        not qast-contains-unfold-local(v)
    }, 'a junction comparison whose value is used keeps the junction';

}
else {
    skip 'the reduced shapes are specific to the RakuAST frontend', 5;
}

# Behavior stays identical.

{
    my Int $x = 5;
    is-deeply ($x ~~ Int, $x ~~ Str, $x !~~ Int), (True, False, False),
        'a declared-type topic still answers each typematch correctly';
    sub typed(Int $a) { $a ~~ Int }
    ok typed(3), 'a typed parameter topic folds to the same answer';
}

{
    my $x = 42;
    is-deeply ($x ~~ 42, $x ~~ 43, $x !~~ 43, $x ~~ "42"), (True, False, True, True),
        'literal matches compare the way their ACCEPTS would';
    is "abc" ~~ 5, False, 'a topic that fails numeric coercion matches no number and does not throw';
    my Int $u;
    todo 'the legacy optimizer answers False for a negated literal match on an undefined topic'
        unless nqp::ifnull(nqp::gethllsym('Raku', 'COMPILER-FRONTEND'), '') eq 'rakuast';
    is-deeply ($u ~~ 42, $u !~~ 42), (False, True),
        'an undefined topic fails a literal match without warning';
    my $j = any(1, 42);
    ok $j ~~ 42, 'a concrete Junction topic still autothreads a literal match';
    is 5 ~~ 5.0, True, 'both sides known folds through the literal ACCEPTS';
}

{
    is-deeply (4 ~~ :is-prime, 7 ~~ :is-prime, 4 ~~ :!is-prime), (False, True, True),
        'Pair matchers ask the method the key names';
    my %h = e => 42;
    is-deeply (%h ~~ :e, %h ~~ :!missing), (True, False),
        'an Associative topic takes the full Pair match';
    my $p = (is-prime => True);
    ok 7 ~~ $p, 'a Pair in a variable keeps the full match and still matches';
}

{
    my $x = 2;
    my @r;
    @r.push('any') if $x == 1|2|3;
    @r.push('none') if $x == 4|5;
    @r.push('all') if $x == 2&2;
    @r.push('not-all') unless $x == 2&3;
    is @r.join(','), 'any,all,not-all', 'unfolded junction conditions branch correctly';
    my $a = 1;
    my $b = 2;
    @r = ();
    @r.push('vars') if $x == $a|$b;
    is @r.join, 'vars', 'a junction built from variables unfolds and still matches';
    my $r = ($x == 1|2);
    isa-ok $r, Junction, 'a junction comparison used as a value stays a Junction';
    my $j = 1|2;
    ok ?($x == $j), 'a junction in a variable is not unfolded and still autothreads';
}
