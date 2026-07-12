use Test;

plan 14;

# A sunk statement-level `for` loop over a CORE integer range compiles to a
# native counting loop. These tests pin the observable behavior: the values
# each range constructor produces, control flow, and the cases that must
# keep the general compilation.

{
    my @seen;
    for 1..5 { @seen.push($_) }
    is-deeply @seen, [1, 2, 3, 4, 5], 'an inclusive .. range produces its values';
}

{
    my @seen;
    for 1..^5 { @seen.push($_) }
    is-deeply @seen, [1, 2, 3, 4], 'a ..^ range excludes its right endpoint';
}

{
    my @seen;
    for 1^..5 { @seen.push($_) }
    is-deeply @seen, [2, 3, 4, 5], 'a ^.. range excludes its left endpoint';
}

{
    my @seen;
    for 1^..^5 { @seen.push($_) }
    is-deeply @seen, [2, 3, 4], 'a ^..^ range excludes both endpoints';
}

{
    my @seen;
    for ^4 { @seen.push($_) }
    is-deeply @seen, [0, 1, 2, 3], 'a ^N range counts from zero';
}

{
    my @seen;
    for (1..4).reverse { @seen.push($_) }
    is-deeply @seen, [4, 3, 2, 1], 'a reversed range counts down';
}

{
    my @seen;
    for -2..2 { @seen.push($_) }
    is-deeply @seen, [-2, -1, 0, 1, 2], 'a range with negative bounds produces its values';
}

{
    my @seen;
    for 5..1 { @seen.push($_) }
    is-deeply @seen, [], 'a range with start past end runs zero times';
}

{
    my @seen;
    @seen.push($_) for ^3;
    is-deeply @seen, [0, 1, 2], 'a modifier for over a range produces its values';
}

{
    my int $n = 3;
    my @seen;
    for 1..$n { @seen.push($_) }
    is-deeply @seen, [1, 2, 3], 'a native int variable works as a range bound';
}

{
    my @seen;
    for 10_000_000_000..10_000_000_002 { @seen.push($_) }
    is-deeply @seen, [10_000_000_000, 10_000_000_001, 10_000_000_002],
        'a range with bounds past 32 bits still produces its values';
}

{
    sub infix:<..>($a, $b) { (42,) }
    my @seen;
    for 3..4 { @seen.push($_) }
    is-deeply @seen, [42], 'a lexically redefined range constructor is honored';
}

{
    my @seen;
    for 1..10 { last if $_ > 3; @seen.push($_) }
    is-deeply @seen, [1, 2, 3], 'last works in a range for loop';
}

{
    my @seen;
    for 1..6 { next if $_ %% 2; @seen.push($_) }
    is-deeply @seen, [1, 3, 5], 'next works in a range for loop';
}
