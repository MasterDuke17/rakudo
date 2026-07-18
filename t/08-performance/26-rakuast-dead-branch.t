use lib <t/packages/Test-Helpers>;
use Test::Helpers::QAST;
use Test;
use QAST:from<NQP>;
use nqp;
plan 3;

# A chaining comparison on constant operands folds to its answer. As a
# link of a longer chain the answer is recorded on the operator rather
# than replacing the link, so the chain protocol holds.

if nqp::ifnull(nqp::gethllsym('Raku', 'COMPILER-FRONTEND'), '') eq 'rakuast' {
    qast-is 'my $r = 2 > 4', :full, -> \v {
        not qast-contains-call(v, '&infix:«>»')
    }, 'a constant chained comparison compiles without the comparison call';
}
else {
    skip 'the folded shape is specific to the RakuAST frontend', 1;
}

{
    is-deeply (2 > 4, 1 < 2 < 3, 3 < 2 < 10), (False, True, False),
        'chained comparisons on constants fold to the runtime answers';
    my $x = 5;
    is (1 < 2 < $x), True, 'a folded link inside a live chain still chains';
}
