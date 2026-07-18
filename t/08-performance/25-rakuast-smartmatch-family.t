use lib <t/packages/Test-Helpers>;
use Test::Helpers::QAST;
use Test;
use QAST:from<NQP>;
use nqp;
plan 3;

# The legacy frontend reduces through its own QAST optimizer, so the
# shapes here are this frontend's.
if nqp::ifnull(nqp::gethllsym('Raku', 'COMPILER-FRONTEND'), '') eq 'rakuast' {
    qast-is 'my Int $x; my $r = $x ~~ Int', :full, -> \v {
        not qast-contains-op(v, 'istype')
    }, 'a typematch guaranteed by the declared type folds away its check';

}
else {
    skip 'the reduced shapes are specific to the RakuAST frontend', 1;
}

# Behavior stays identical.

{
    my Int $x = 5;
    is-deeply ($x ~~ Int, $x ~~ Str, $x !~~ Int), (True, False, False),
        'a declared-type topic still answers each typematch correctly';
    sub typed(Int $a) { $a ~~ Int }
    ok typed(3), 'a typed parameter topic folds to the same answer';
}
