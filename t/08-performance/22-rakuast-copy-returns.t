use lib <t/packages/Test-Helpers>;
use Test::Helpers;
use Test::Helpers::QAST;
use Test;
use QAST:from<NQP>;
use nqp;
plan 9;

# A call to a routine bound once carries the callee's declared return type
# on its QAST, and a native return is offered both boxed and raw through a
# Want, so a native consumer skips the boxing round trip.

my $rakuast = nqp::ifnull(nqp::gethllsym('Raku', 'COMPILER-FRONTEND'), '') eq 'rakuast';

# These observe the emitted QAST. The legacy optimizer does not offer this
# shape both ways, so the box assertions hold for the RakuAST frontend only.
todo 'the legacy optimizer does not box a native return through a Want', 2
    unless $rakuast;
qast-is 'sub cr-a(--> int) { return 3 }; my int $x = cr-a()', -> \v {
    qast-contains-op(v, 'p6box_i')
}, 'a native int return is offered boxed through a Want';

qast-is 'sub cr-b(--> num) { return 3e0 }; my num $x = cr-b()', -> \v {
    qast-contains-op(v, 'p6box_n')
}, 'a native num return is offered boxed through a Want';

qast-is 'sub cr-c(--> Int) { return 3 }; my $x = cr-c()', -> \v {
    not qast-contains-op(v, 'p6box_i')
}, 'a boxed return type adds no boxing op';

# These observe that returns still behave.
{
    sub f(--> int) { return 3 }
    my int $x = f();
    is $x, 3, 'a native int return reaches a native target';
    is f() + 1, 4, 'a native int return computes in object context';
}
{
    sub f(--> num) { return 1.5e0 }
    is f() * 2, 3e0, 'a native num return computes';
}
{
    sub f(--> str) { return "hi" }
    is f() ~ "!", 'hi!', 'a native str return computes';
}
{
    sub f(--> Str) { return "ok" }
    is f(), 'ok', 'a boxed declared return gives its value';
}
{
    # An our-scoped callee imports as its Scalar container, so the return
    # type of the value it happens to hold at compile time is no promise.
    my $dir = make-temp-dir;
    $dir.add('ReassignableCallee.rakumod').spurt:
        'our &rc = sub (--> int) { 1 }';
    todo 'the legacy optimizer copies a reassignable imported callee return type'
        unless $rakuast;
    is-deeply
        (try EVAL q[use lib $dir; use ReassignableCallee; &rc = sub (--> Str) { "s" }; rc()]) // 'died',
        "s",
        'an imported our-scoped callee reassigned at runtime returns the new value';
}

# vim: expandtab shiftwidth=4
