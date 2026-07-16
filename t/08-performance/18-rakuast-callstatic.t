use lib <t/packages/Test-Helpers>;
use Test::Helpers::QAST;
use Test;
use QAST:from<NQP>;
use nqp;
plan 9;

# A call to a named setting routine compiles its callee lookup as a static
# one, which the VM may resolve a single time. A routine declared in user
# code keeps the plain lookup, since its binding may be a fresh clone per
# scope entry.

sub qast-op-named (Mu $qast, Str:D $op, Str:D $name --> Bool:D) {
    if nqp::istype($qast, QAST::Op) && $qast.op eq $op && $qast.name eq $name {
        return True;
    }
    elsif qast-descendable $qast {
        for $qast.list {
            qast-op-named $_, $op, $name and return True;
        }
    }
    False
}

# These observe the emitted QAST.
qast-is 'my $x = 1; say $x', -> \v {
        qast-op-named(v, 'callstatic', '&say')
    and not qast-op-named(v, 'call', '&say')
}, 'a call to a setting routine compiles to a static callee lookup';

qast-is 'my $s = "hi"; chars $s', -> \v {
        qast-op-named(v, 'callstatic', '&chars')
    and not qast-op-named(v, 'call', '&chars')
}, 'a setting routine whose value is used compiles to a static callee lookup';

qast-is '{ my sub f($x) { return $x + 1 }; f(1) }', :full, -> \v {
        qast-op-named(v, 'call', '&f')
    and not qast-op-named(v, 'callstatic', '&f')
}, 'a call to a nested user routine keeps the plain callee lookup';

# These observe that statically looked up callees still behave.
{
    my $s = "HI";
    is chars($s), 2, 'a setting routine called by name returns its value';
}
{
    sub f { return 42; 99 }
    is f(), 42, 'return unwinds through a static callee lookup';
}
{
    is (gather { take 1; take 2 }).join(','), '1,2',
        'take reaches the enclosing gather through a static callee lookup';
}
{
    sub g { fail "nope" }
    ok g() ~~ Failure, 'fail produces a Failure through a static callee lookup';
}
{
    my @a = 1, 2, 3;
    is elems(@a), 3, 'a multi setting routine called by name returns its value';
}
{
    my $out = do { use soft; my $s = "hi"; uc $s };
    is $out, 'HI', 'a setting routine still runs under the soft pragma';
}

# vim: expandtab shiftwidth=4
