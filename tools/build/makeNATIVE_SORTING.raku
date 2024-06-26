#!/usr/bin/env raku

# This script reads the Rakudo/Sorting.pm6 file, generates the
# logic to sort a native str, int, uint num array in place, and
# writes it back to the file.

# always use highest version of Raku
use v6.*;

my $generator = $*PROGRAM-NAME;
my $generated = DateTime.now.gist.subst(/\.\d+/,'');
my $start     = '#- start of generated part of sorting ';
my $idpos     = $start.chars;
my $idchars   = 3;
my $end       = '#- end of generated part of sorting ';

# slurp the whole file and set up writing to it
my $filename = "src/core.c/Rakudo/Sorting.pm6";
my @lines = $filename.IO.lines;
$*OUT = $filename.IO.open(:w);

my %type_mapper = (
  int => ( :base_postfix<i>,
           :postfix<i>,
           :type<int>,
         ).Map,
  num => ( :base_postfix<n>,
           :postfix<n>,
           :type<num>,
         ).Map,
  str => ( :base_postfix<s>,
           :postfix<s>,
           :type<str>,
         ).Map,
  uint => ( :base_postfix<i>,
            :postfix<u>,
            :type<uint>,
          ).Map,
);


# for all the lines in the source that don't need special handling
while @lines {
    my $line := @lines.shift;

    # nothing to do yet
    unless $line.starts-with($start) {
        say $line;
        next;
    }

    # found header, check validity and set up mapper
    my $type = $line.substr($idpos,$idchars);
    $type = "uint" if $type eq "uin";
    die "Don't know how to handle $type"
      unless my %mapper := %type_mapper{$type};

    say $start ~ $type ~ "array logic --------------------------";
    say "#- Generated on $generated by $generator";
    say "#- PLEASE DON'T CHANGE ANYTHING BELOW THIS LINE";

    # skip the old version of the code
    while @lines {
        last if @lines.shift.starts-with($end);
    }
    # spurt the code
    say Q:to/SOURCE/.subst(/ '#' (\w+) '#' /, -> $/ { %mapper{$0} }, :g).chomp;

    # https://en.wikipedia.org/wiki/Merge_sort#Bottom-up_implementation
    # Sort a native #type# array (or nqp::list_#base_postfix#) and return the result.
    # Uses the given #type# array as one of the buffers for performance reasons.
    # Please nqp::clone first if you want to keep the original intact.
    method MERGESORT-#type#(Mu \sortable) {
        nqp::if(
          nqp::isgt_i((my int $n = nqp::elems(sortable)),2),

          # $A has the items to sort; $B is a work array
          nqp::stmts(
            (my Mu $A := sortable),
            (my Mu $B := nqp::setelems(nqp::create(nqp::what(sortable)),$n)),

            # Each 1-element run in $A is already "sorted"
            # Make successively longer sorted runs of length 2, 4, 8, 16...
            # until $A is wholly sorted
            (my int $width = 1),
            nqp::while(
              nqp::islt_i($width,$n),
              nqp::stmts(
                (my int $l = 0),

                # $A is full of runs of length $width
                nqp::while(
                  nqp::islt_i($l,$n),

                  nqp::stmts(
                    (my int $left  = $l),
                    (my int $right = nqp::add_i($l,$width)),
                    nqp::if(nqp::isge_i($right,$n),($right = $n)),
                    (my int $end =
                      nqp::add_i($l,nqp::add_i($width,$width))),
                    nqp::if(nqp::isge_i($end,$n),($end = $n)),

                    (my int $i = $left),
                    (my int $j = $right),
                    (my int $k = nqp::sub_i($left,1)),

                    # Merge two runs: $A[i       .. i+width-1] and
                    #                 $A[i+width .. i+2*width-1]
                    # to $B or copy $A[i..n-1] to $B[] ( if(i+width >= n) )
                    nqp::while(
                      nqp::islt_i(++$k,$end),
                      nqp::if(
                        nqp::islt_i($i,$right) && (
                          nqp::isge_i($j,$end)
                            || nqp::islt_#base_postfix#(
                                 nqp::atpos_#postfix#($A,$i),
                                 nqp::atpos_#postfix#($A,$j)
                               )
                        ),
                        nqp::stmts(
                          nqp::bindpos_#postfix#($B,$k,nqp::atpos_#postfix#($A,$i)),
                          ++$i
                        ),
                        nqp::stmts(
                          nqp::bindpos_#postfix#($B,$k,nqp::atpos_#postfix#($A,$j)),
                          ++$j
                        )
                      )
                    ),
                    ($l = nqp::add_i($l,nqp::add_i($width,$width)))
                  )
                ),

                # Now work array $B is full of runs of length 2*width.
                # Copy array B to array A for next iteration.  A more
                # efficient implementation would swap the roles of A and B.
                (my Mu $temp := $B),($B := $A),($A := $temp),   # swap
                # Now array $A is full of runs of length 2*width.

                ($width = nqp::add_i($width,$width))
              )
            ),
            $A
          ),
          nqp::stmts(   # 2 elements or less
            (my \result := nqp::clone(sortable)),
            nqp::unless(
              nqp::islt_i($n,2)
                || nqp::isle_#base_postfix#(nqp::atpos_#postfix#(result,0),nqp::atpos_#postfix#(result,1)),
              nqp::push_#base_postfix#(result,nqp::shift_#base_postfix#(result))
            ),
            result
          )
        )
    }
SOURCE

    # we're done for this role
    say "#- PLEASE DON'T CHANGE ANYTHING ABOVE THIS LINE";
    say $end ~ $type ~ "array logic ----------------------------";
}

# close the file properly
$*OUT.close;

# vim: expandtab sw=4
