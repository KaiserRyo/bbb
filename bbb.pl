#!/usr/bin/perl
use Getopt::Long;
use Cwd;
use YAML ();

use Device;
use Manifest;
use v5.10;
use strict;
no warnings 'experimental';

our $options = {
	ip => '169.254.0.1',
	password => '',
	keyid => '',
	dir => getcwd . '/out',
};

if (-f "$ENV{HOME}/.bbb_config.yaml") {
	my $cfg_options = YAML::LoadFile("$ENV{HOME}/.bbb_config.yaml");
	$options = {
		%$options,
		%$cfg_options,
	};
}

GetOptions(
	"ip=s" => \$options->{ip},
	"password=s" => \$options->{password},
	"dir=s" => \$options->{dir},
) or die "Error in command line arguments";

my $dev = Device->new(ip => $options->{ip});
#$dev->discover;
$dev->login($options->{password});

given ($ARGV[0]) {
	when ('list') {
		my $list = $dev->backup_list;

		my @categories = @{$list->{BackupList}->{Categories}->{Category}};
		for my $c (@categories) {
			say "=== $c->{id}->{value}";
			if ($c->{SubCategories}) {
				my @subcategories = @{$c->{SubCategories}->{SubCategory}};
				for my $sc (@subcategories) {
					my $type = $sc->{type}->{value};
					my $name = $sc->{name}->{value};
					my $pkgid = $sc->{pkgid}->{value};
					my $size = $sc->{bytesize}->{value};
					printf("  %-10s%-30s%-30s%d\n", $type, $name, $pkgid, $size);
				}
			}
		}
	}

	when ('backup') {
		my $list = $dev->backup_list;
		my @items;

		my @categories = @{$list->{BackupList}->{Categories}->{Category}};
		for my $c (@categories) {
			if ($c->{SubCategories}) {
				my @subcategories = @{$c->{SubCategories}->{SubCategory}};
				for my $sc (@subcategories) {
					push(@items, {
						category => 'app',
						map {
							$_ => $sc->{$_}->{value}
						} qw{type name pkgid bytesize count detail version}
					});
				}
			} else {
				push(@items, {
					category => $c->{id}->{value},
					pkgid => $c->{id}->{value},
					name => $c->{id}->{value},
					size => $c->{bytesize}->{value},
				});
			}
		}

		@items = grep { $_->{name} =~ /$ARGV[1]/i } @items;

		$dev->backup($options, @items);
	}

	when('restore') {
		my $manifest = Manifest->new("$options->{dir}/Manifest.xml");
		my @archives = $manifest->archives;

		# Reorder archives for better restore?
		@archives = (
			grep({ $_->{id} eq 'media' } @archives),
			grep({ $_->{id} eq 'settings' } @archives),
			grep({ $_->{id} eq 'systemapps' } @archives),
			grep({ $_->{type} ~~ ['bin', 'data'] } @archives),
		);

		$dev->restore($options, @archives);
	}

	default {
		say "$0 [list|backup|restore]";
	}
}
