# Waits for a promise to be kept or a channel to be able to receive a value
# and, once it can, unwraps or returns the result. Under Perl 6.c, await will
# really block the calling thread. In 6.d, if the thread is on the thread pool
# then a continuation will be taken, and the thread is freed up.

my role X::Await::Died {
    has $.await-backtrace;
    multi method gist(::?CLASS:D:) {
        "An operation first awaited:\n" ~
            ((try $!await-backtrace ~ "\n") // '<unknown location>') ~
            "Died with the exception:\n" ~
            callsame().indent(4)
    }
}

proto sub await(|) { * }
multi sub await() {
    die "Must specify a Promise or Channel to await on (got an empty list)";
}
multi sub await(Any:U $x) {
    die "Must specify a defined Promise, Channel, or Supply to await on (got an undefined $x.^name())";
}
multi sub await(Any:D $x) {
    die "Must specify a Promise, Channel, or Supply to await on (got a $x.^name())";
}
multi sub await(Promise:D $p) {
    CATCH {
        unless nqp::istype($_, X::Await::Died) {
            ($_ but X::Await::Died(Backtrace.new(5))).rethrow
        }
    }
    my $*RAKUDO-AWAIT-BLOCKING := True;
    $*AWAITER.await($p)
}
multi sub await(Channel:D $c) {
    CATCH {
        unless nqp::istype($_, X::Await::Died) {
            ($_ but X::Await::Died(Backtrace.new(5))).rethrow
        }
    }
    my $*RAKUDO-AWAIT-BLOCKING := True;
    $*AWAITER.await($c)
}
multi sub await(Supply:D $s) {
    CATCH {
        unless nqp::istype($_, X::Await::Died) {
            ($_ but X::Await::Died(Backtrace.new(5))).rethrow
        }
    }
    my $*RAKUDO-AWAIT-BLOCKING := True;
    $*AWAITER.await($s)
}
multi sub await(Iterable:D $i) { $i.eager.map({ await $_ }) }
multi sub await(*@awaitables)  { @awaitables.eager.map({await $_}) }

sub awaiterator(@promises) {
    Seq.new(class :: does Iterator {
        has @!todo;
        has @!done;
        method !SET-SELF(\todo) { @!todo = todo; self }
        method new(\todo) { nqp::create(self)!SET-SELF(todo) }
        method pull-one() is raw {
            if @!done {
                @!done.shift
            }
            elsif @!todo {
                Promise.anyof(@!todo).result;
                my @next;
                .status == Planned
                  ?? @next.push($_)
                  !! @!done.push($_.result)
                    for @!todo;
                @!todo := @next;
                @!done.shift
            }
            else {
                IterationEnd
            }
        }
        method sink-all(--> IterationEnd) { Promise.allof(@promises).result }
    }.new(@promises))
}

# vim: ft=perl6 expandtab sw=4
