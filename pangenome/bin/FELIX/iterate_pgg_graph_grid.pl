#!/usr/bin/env perl
#Copyright (C) 2017-2022 The J. Craig Venter Institute (JCVI).  All rights reserved #This program is free software: you can redistribute it and/or modify #it under the terms of the GNU General Public License as published by #the Free Software Foundation, either version 3 of the License, or #(at your option) any later version.

#This program is distributed in the hope that it will be useful, #but WITHOUT ANY WARRANTY; without even the implied warranty of #MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the #GNU General Public License for more details.

#You should have received a copy of the GNU General Public License #along with this program.  If not, see <http://www.gnu.org/licenses/>.

# pgg re-annotation wrapper script for grid
use Cwd;
use FileHandle;
use Getopt::Long;
use Carp;
use strict;
use File::Compare;

my $bin_directory = "/usr/local/projdata/8520/projects/PANGENOME/pangenome_bin/";
my $input_bin_directory = "";
my @genomes = ();                                                                              
my $max_iterate = 1;                                                                           # if no iteration count is set, default is 1
my $single_copy = "single_copy_clusters.txt";
my $core_neighbors = "core_neighbors"; # is the file the core neighbors is stored in
my $stats = "output/cluster_stats.txt";
my $genome_list_path = "";
my $weights = "cluster_sizes.txt";
my $project = "8520";
my $paralogs = "";
my $input_single_copy = "";
my $pgg = "pgg.txt";                                                               # [pangenome_dir]/0_core_adjacency_vector.txt
my $medoids = "medoids.fasta";
my $matchtable = "matchtable.txt";                                                      # [pangenome_dir]/matchtable.txt
my $id = 95;
my $debug = 0;
my $help = 0;
my $logfile = "iterate_ppg_graph.logfile";
my $topology_file = "topology.txt";
my $cwd = getcwd;

GetOptions('genomes=s' => \ $genome_list_path,
	   'weights=s' => \ $weights,
	   'project=s' => \ $project,
	   'paralogs=s' => \ $paralogs,
	   'topology=s' => \ $topology_file,
	   'single_copy=s' => \ $input_single_copy,
	   'bin_directory=s' => \ $input_bin_directory,
	   'pgg=s' => \ $pgg,                                                               # [pangenome_dir]/0_core_adjacency_vector.txt
	   'medoids=s' => \ $medoids,
	   'match=s' => \ $matchtable,                                                      # [pangenome_dir]/matchtable.txt
	   'iterations=i' => \ $max_iterate,
	   'id=i' => \ $id,
	   'strip_version' => \my $strip_version,
	   'debug' => \ $debug,
	   'help' => \ $help);
if ($help) {
   system("clear");
   print STDERR <<_EOB_;
GetOptions('genomes=s' => \ genome_list_path,
	   'weights=s' => \ weights,
	   'project=s' => \ project,
	   'paralogs=s' => \ paralogs,
	   'topology=s' => \ topology_file,
	   'single_copy=s' => \ input_single_copy,
	   'bin_directory=s' => \ input_bin_directory,
	   'pgg=s' => \ pgg,                                                               # [pangenome_dir]/0_core_adjacency_vector.txt
	   'medoids=s' => \ medoids,
	   'match=s' => \ matchtable,                                                      # [pangenome_dir]/matchtable.txt
	   'iterations=i' => \ max_iterate,
	   'id=i' => \ id,
	   'strip_version' => \ strip_version,
	   'debug' => \ debug,
	   'help' => \ help);
_EOB_
    exit(0);
}

if ($input_bin_directory) {
    if (-d $input_bin_directory) {
	if (substr($input_bin_directory, 0, 1) ne "/") {
	    $input_bin_directory = $cwd . "/$input_bin_directory";
	}
    } else {
	die "The specified bin directory: $input_bin_directory does not exist!\n";
    }
    $bin_directory = $input_bin_directory;
}

if ($paralogs && $input_single_copy) {
    die "You can only specify a paralogs file or a single copy clusters file but not both!\n";
} elsif (!$paralogs && !$input_single_copy) {
    die "You must specify either a paralogs file or a single copy clusters file!\n";
} elsif ($input_single_copy) {
    `cp $input_single_copy $single_copy`;
}
if (substr($weights, 0, 1) ne "/") {
    $weights = $cwd . "/$weights";
}
if (substr($medoids, 0, 1) ne "/") {
    $medoids = $cwd . "/$medoids";
}
if (substr($pgg, 0, 1) ne "/") {
    $pgg = $cwd . "/$pgg";
}
if ($debug) {print "Parameters:\ngenomes: $genome_list_path\nweights: $weights\nparalogs: $paralogs\npgg: $pgg\nmedoids: $medoids\nmatch: $matchtable\nid: $id\niterations: $max_iterate\nsingle_copy_clusters: $single_copy\n";}
			
######################################COMPONENT PROGRAM PATHS################################
my $single_copy_path = "$bin_directory/single_copy_core.pl";
my $core_neighbor_path = "$bin_directory/core_neighbor_finder.pl";
my $medoid_blast_path = "$bin_directory/medoid_blast_search.pl";
my $pgg_annotate_path = "$bin_directory/pgg_annotate.pl";
my $pgg_multifasta_path = "$bin_directory/pgg_edge_multifasta.pl";
my $pgg_combine_edges_path = "$bin_directory/pgg_combine_edges.pl";
my $compute_path = "$bin_directory/compute_pgg_graph.pl";
my $compute_new_clusters_path = "$bin_directory/compute_new_clusters.pl";
#############################################################################################

sub bash_error_check {
    my ($command, $error, $message) = @_;
    if (!$error) {
	return;
    }
    print STDERR "$command FAILED\n";
    if ($error == -1) {
	printf STDERR "failed to execute code(%d): %s\n", $error >> 8, $message;
    } elsif ($error & 127) {
	printf STDERR "child died with code %d signal %d, %s coredump\n", $error >> 8, ($error & 127),  ($error & 128) ? 'with' : 'without';
    } else {
	printf STDERR "child exited with value %d\n", $error >> 8;
    }
    return;
}

sub launch_grid_job {
# Given a shell script, launch it via qsub.

    my ( $name, $project_code, $working_dir, $shell_script, $stdoutdir, $stderrdir, $queue, $job_array_max ) = @_;

    my $qsub_command = "qsub -V -P $project_code -o $stdoutdir -e $stderrdir -wd $working_dir -r n -N $name";
    $qsub_command .= " -l $queue" if $queue;
    $qsub_command .= " -t 1-$job_array_max" if $job_array_max;

    $qsub_command .= " $shell_script";

    my $response = `$qsub_command`;
    my $job_id;

    if ($response =~ (/Your job (\d+) \(.*\) has been submitted/) || $response =~ (/Your job-array (\d+)\./)) {

        $job_id = $1;

    } else {
        die "Problem submitting the job!: $response";
    }

    return $job_id;

}


sub wait_for_grid_jobs {
    # Given a hash of job ids wait until hash is reduced to number of jobs specified and return number of jobs; name is the job name
    
    my ( $name, $number, $job_ids ) = @_;
    my $size = scalar( keys %{$job_ids} );

    while ( $size > $number ) {
	sleep 60;
	my $response = `qacct -j $name 2>&1`;
	&parse_response( $response, $job_ids );
	$size = scalar( keys %{$job_ids} );
    }
    return ($size);
}


sub parse_response {
# NOT INTENDED TO BE CALLED DIRECTLY.
# Given a qacct response, delete a job id from the loop-control-hash when
# a statisfactory state is seen.

    my ( $response, $job_ids ) = @_;
    my @qacct_array = split ( /=+\n/, $response );
    if (scalar(@qacct_array) <= 1) {
	return; # jobs haven't hit the grid yet
    }
    shift @qacct_array; # get rid of empty record at beginning.

    for my $record ( @qacct_array ) {

        next if ( $record =~ /error: ignoring invalid entry in line/ );

        chomp $record;

        my @rec_array = split ( "\n", $record );

        for my $line (@rec_array) {

            $line =~ s/(.*\S)\s+$/$1/;
            my ( $key, $value ) = split ( /\s+/, $line, 2 );
	    if ($key eq "jobnumber") {
		if ( defined $job_ids->{$value} ) {
		    delete ( $job_ids->{$value} )
		}
	    }
	}
    }
    return;
}

# get first line of matchtable and pgg
# get core list
# generate pgg neighbor data
# read genome list
# run through genomes one at a time, doing blast then pgg_annotate, and adding match_table and pgg data to files
# check if there is a difference in pgg file
# if so, iterate the pgg_portion

#############################################################################################
sub do_core_list
# run single_copy_core.pl to generate input for pgg_annotate.pl
{
    if ($debug) {print "\nperl $single_copy_path -s $weights -p $paralogs -c $id > $single_copy\n";}
    `perl $single_copy_path -s $weights -p $paralogs -c $id > $single_copy 2>> $logfile`;
    &bash_error_check("perl $single_copy_path -s $weights -p $paralogs -c $id > $single_copy 2>> $logfile", $?, $!);
}
#############################################################################################
sub do_neighbors
# run core_neighbor_finder.pl to generate input for pgg_annotate.pl
{
    if ($debug) {print "\nperl $core_neighbor_path -v $pgg -cl $single_copy\n";}
    `perl $core_neighbor_path -v $pgg -cl $single_copy >> $logfile 2>&1`;
    &bash_error_check("perl $core_neighbor_path -v $pgg -cl $single_copy >> $logfile 2>&1", $?, $!);
}
#############################################################################################
sub load_genomes
# read in list of identifiers and genomes paths, store them so that this file doesn't need to be queried if the re-annotation is iterative
{
    open(GENOMES, "<", "$genome_list_path");
    my $count = 0;
    while (my $line = <GENOMES>)
    {
	chomp($line);                                                               # strip newline character
	my @split_line = split(/\t/, $line);                                        # split on tab
	$genomes[$count][0] = $split_line[0];                                       # store identifier in 0
	$genomes[$count][1] = $split_line[1];                                       # store fasta path in 1
	$count++;                                                                   # increment counter
    }
    close(GENOMES);
    return $count;
}
######################################################################################################################################################################
sub read_topology {

    unless (open (CIRCFILE, "<", "$topology_file") )  {
	die ("ERROR: can not open contig topology file $topology_file.\n");
    }
    my $cur_tag = "";
    while (<CIRCFILE>) {
	my $tag = "";
	my $asmbl_id = "";
	my $type = "";

	($tag, $asmbl_id, $type) = split(/\t/, $_);  # split the scalar $line on tab
	if (($tag eq "") || ($asmbl_id eq "") || ($type eq "")) {
	    die ("ERROR: genome id, assembly id/contig id, and type  must not be empty/null in the contig topology file $topology_file.\nLine:\n$_\n");
	}
	$cur_tag = $tag;
	
	unless (open (TOPFILE, ">", $cur_tag . "_topology.txt") )  {
	    die ("ERROR: can not open contig topology file $cur_tag" . "_topology.txt.\n");
	}
	print TOPFILE $_;
	last;
    }
    while (<CIRCFILE>) {
	my $tag = "";
	my $asmbl_id = "";
	my $type = "";

	($tag, $asmbl_id, $type) = split(/\t/, $_);  # split the scalar $line on tab
	if (($tag eq "") || ($asmbl_id eq "") || ($type eq "")) {
	    die ("ERROR: genome id, assembly id/contig id, and type  must not be empty/null in the contig topology file $topology_file.\nLine:\n$_\n");
	}
	if ($tag ne $cur_tag) {
	    close (TOPFILE);
	    $cur_tag = $tag;
	    unless (open (TOPFILE, ">", $cur_tag . "_topology.txt") )  {
		die ("ERROR: can not open contig topology file $cur_tag" . "_topology.txt.\n");
	    }
	}
	print TOPFILE $_;
    }
    close (TOPFILE);
    close (CIRCFILE);
    return;
}
#############################################################################################
sub compute
# go through all genomes, run BLAST, run pgg_annotate (building matchtable and pgg edges files as we go), then, see if there is a difference, and re-run if necessary
{
    `cut -f 1 $genome_list_path > Genomes.List`;
    if ($debug) {print "Starting compute ...\n\n";}
    for (my $i=1; $i <= $max_iterate; $i++)
    {
	my $job_name = "cpgg_" . $$ . "$i"; #use a common job name so that qacct can access all of them together
	my %job_ids = ();
	my $num_jobs = 0;
	my $pgg_old = $pgg;
	if ($debug) {print "Iteration $i\n";}
	&do_neighbors;                                                                                 # run core_neighbor_finder
	`cut $matchtable -f1 > matchtable.col`;                                                        # get first line of existing matchtable file, use that as first column of new file
	`cut $pgg -f1 > pgg.col`;                
	open(GENEANI, ">", "gene_ANI");
	open(REARRANGE, ">", "rearrange");
	open(ALLEDGES, ">", "AllEdges");
	# print headers to columns that are new (currently gene_ANI, rearrange, and wgsANI)
	print GENEANI "geneANI\n";
	print REARRANGE "rearrange\n";
	`echo "wgsANI" > wgs_ANI`;
	for (my $j=0; $j <= $#genomes; $j++)
	{
	    my $identifier = $genomes[$j][0];                                                 # get genome name
	    my $genome_path = $genomes[$j][1];                                                # get genome path
	    if (substr($genome_path, 0, 1) ne "/") {
		$genome_path = $cwd . "/$genome_path";
	    }
	    my $shell_script = "$compute_path -reannotate -name $identifier -genome $genome_path -weights $weights -medoids $medoids -pgg $pgg -debug";
	    if ($strip_version) {
		$shell_script .= " -strip_version";
	    }
	    my $stdoutfile = $cwd . "/" . $identifier . "_stdout";
	    my $stderrfile = $cwd . "/" . $identifier . "_stderr";
	    my $working_dir = $cwd . "/TMP_" . $identifier;
	    my $queue = "himem";
	    my $match_name = ("$identifier" . "_match.col");
	    my $pgg_name = ("$identifier" . "_pgg.col");
	    my $att_name = ("$identifier" . "_attributes.txt");
	    my $topology_name = ("$identifier" . "_topology.txt");
	    if ((-e $match_name) && (-e $pgg_name) && (-e $att_name)){
		next; #we have already annotated this genome in a previous aborted run
	    }
	    `mkdir TMP_$identifier`;
	    `ln $topology_name $single_copy $core_neighbors TMP_$identifier`;
	    if ($debug) {print "\nidentifier: $identifier \t path: $genome_path\n\n";}
	    if ($debug) {print "qsub $shell_script\n";}
	    $job_ids{&launch_grid_job($job_name, $project, $working_dir, $shell_script, $stdoutfile, $stderrfile, $queue)} = 1;
	    $num_jobs++;
	    if ($num_jobs >= 50) {
		$num_jobs = &wait_for_grid_jobs($job_name, 40, \%job_ids);
	    }
	}
	&wait_for_grid_jobs($job_name, 0, \%job_ids);
	`rm -r TMP_*`;
	if ($debug) {print "removed TMP directories\n";}
	    
	$num_jobs = 0;
	for (my $j=0; $j <= $#genomes; $j++)
	{
	    my $identifier = $genomes[$j][0];                                                 # get genome name
	    my $genome_path = $genomes[$j][1];                                                # get genome path
	    my $match_name = ("$identifier" . "_match.col");
	    my $pgg_name = ("$identifier" . "_pgg.col");
	    my $att_name = ("$identifier" . "_attributes.txt");
	    if (!(-e $match_name) || !(-e $pgg_name) || !(-e $att_name)){
		$num_jobs++;
	    }
	}
	if ($debug) {print "$num_jobs FAILED resubmitting\n";}
	if ($num_jobs > 50) {
	    die "Too many grid jobs failed $num_jobs\n";
	} elsif ($num_jobs > 0) {
	    for (my $k=0; $k <= 2; $k++){ #try a maximum of 3 times on failed jobs
		if ($debug) {print "Resubmit $num_jobs jobs Iteration $k\n";}
		%job_ids = ();
		$num_jobs = 0;
		for (my $j=0; $j <= $#genomes; $j++)
		{
		    my $identifier = $genomes[$j][0];                                                 # get genome name
		    my $genome_path = $genomes[$j][1];                                                # get genome path
		    if (substr($genome_path, 0, 1) ne "/") {
			$genome_path = $cwd . "/$genome_path";
		    }
		    my $match_name = ("$identifier" . "_match.col");
		    my $pgg_name = ("$identifier" . "_pgg.col");
		    my $att_name = ("$identifier" . "_attributes.txt");
		    if (!(-e $match_name) || !(-e $pgg_name) || !(-e $att_name)){
			my $shell_script = "$compute_path -reannotate -name $identifier -genome $genome_path -weights $weights -medoids $medoids -pgg $pgg -debug";
			if ($strip_version) {
			    $shell_script .= " -strip_version";
			}
			my $stdoutfile = $cwd . "/" . $identifier . "_stdout";
			my $stderrfile = $cwd . "/" . $identifier . "_stderr";
			my $working_dir = $cwd . "/TMP_" . $identifier;
			my $topology_name = ("$identifier" . "_topology.txt");
			my $queue = "himem";
			`mkdir TMP_$identifier`;
			`ln $topology_name $single_copy $core_neighbors TMP_$identifier`;
			if ($debug) {print "\nidentifier: $identifier \t path: $genome_path\n\n";}
			if ($debug) {print "resubmit qsub $shell_script\n";}
			$job_ids{&launch_grid_job($job_name, $project, $working_dir, $shell_script, $stdoutfile, $stderrfile, $queue)} = 1;
			$num_jobs++;
		    }
		}
		if ($num_jobs == 0) {
		    last; # no failed jobs
		}
		if ($debug) {print "$num_jobs relaunched\n";}
		&wait_for_grid_jobs($job_name, 0, \%job_ids);
		`rm -r TMP_*`;
		if ($debug) {print "removed resubmitted TMP directories\n";}
	    }
	}

	for (my $j=0; $j <= $#genomes; $j++)
	{
	    my $identifier = $genomes[$j][0];                                                 # get genome name
	    my $genome_path = $genomes[$j][1];                                                # get genome path
	    my $all_edges = ("$identifier" . "_alledges.txt");
	    my $match_name = ("$identifier" . "_match.col");
	    my $pgg_name = ("$identifier" . "_pgg.col");
	    my $gene_ani_name = ("$identifier" . "_geneANI.txt");
	    my $rearrange_name = ("$identifier" . "_rearrange.txt");
	    my $wgs_ani_name = ("$identifier" . "_wgsANI.txt");
	    my $match_name_new = ("$identifier" . "_match_new.col");
	    my $pgg_name_new = ("$identifier" . "_pgg_new.col");
	    my $att_name = ("$identifier" . "_attributes.txt");
	    my $att_name_new = ("$identifier" . "_attributes_new.txt");
	    my $new_seqs_name = ("$identifier" . "_seqs.fasta");
	    my $new_clusters_name = ("$identifier" . "_new_clus.txt");
	    my $gene_ani = `wc -l < $gene_ani_name`;
	    my $rearrange = `wc -l < $rearrange_name`;
	    my $stdoutfile = $identifier . "_stdout";
	    my $stderrfile = $identifier . "_stderr";
	    if ($debug) {print "\nmatchname: $match_name \t pggname: $pgg_name \n";}
	    die ("$match_name doesn't exist \n") unless (-e $match_name);
	    die ("$pgg_name doesn't exist \n") unless (-e $pgg_name);
	    die ("$att_name doesn't exist \n") unless (-e $att_name);
	    `cat $att_name_new >> $att_name`; # add the new attributes to the existing attributes for reannotation purposes
	    `cat $new_seqs_name >> new_gene_seqs.fasta`;
	    `cat $new_clusters_name >> new_clusters.txt`;
	    `rm $new_seqs_name $new_clusters_name`;
	    print ALLEDGES "$all_edges\n";
	    print GENEANI "$gene_ani";
	    print REARRANGE "$rearrange";
	    `cat $wgs_ani_name >> wgs_ANI`;                                                    # we don't need to do a line-count here, we just copy over the entire one-line file
	    `paste matchtable.col $match_name > tmp.matchtable.col`;                           # paste line frome matchtable
	    `paste pgg.col $pgg_name > tmp.pgg.col`;                                           # paste line from edges file
	    die ("tmp.matchtable.col is zero size \n") unless (-s "tmp.matchtable.col");
	    die ("tmp.pgg.col is zero size \n") unless (-s "tmp.pgg.col");
	    `mv tmp.matchtable.col matchtable.col`;                                            # rename file
	    `mv tmp.pgg.col pgg.col`;                                                         # rename file
	    if ($j==0)
	    {
		`cat $att_name > combined.att`;                                       # overwrite combined file from past iteration
	    } else 
	    {
		`cat $att_name >> combined.att`;                                      # add to combined file
	    }
	    # clean up
	    `rm $match_name $pgg_name $att_name $gene_ani_name $rearrange_name $wgs_ani_name $match_name_new $pgg_name_new $att_name_new $stdoutfile $stderrfile`;
	}
	close(ALLEDGES);
	close(GENEANI);
	close(REARRANGE);
	my $start_new_cluster_num = `wc -l < matchtable.col` + 1;
	if (-s "new_clusters.txt") {
	    if ($debug) {print "\nperl $compute_new_clusters_path -c new_clusters.txt -g Genomes.List -s new_gene_seqs.fasta -n $start_new_cluster_num -i IndexNewClusters -M NewMatches -m NewMedoids\n";}
	    `perl $compute_new_clusters_path -c new_clusters.txt -g Genomes.List -s new_gene_seqs.fasta -n $start_new_cluster_num -i IndexNewClusters -M NewMatches -m NewMedoids >> $logfile 2>&1`; # run compute_new_clusters
	    die ("IndexNewClusters is zero size \n") unless (-s "IndexNewClusters");
	    &bash_error_check("perl $compute_new_clusters_path -c new_clusters.txt -g Genomes.List -s new_gene_seqs.fasta -n $start_new_cluster_num -i IndexNewClusters -M NewMatches -m NewMedoids >> $logfile 2>&1", $?, $!);
	    `rm new_gene_seqs.fasta`;
	    `cat NewMatches >> matchtable.col`;
	    `rm NewMatches`;
	    `cat NewMedoids >> $medoids`;
	    `rm NewMedoids`;
	    `rm new_clusters.txt`;
	    if ($debug) {print "\nperl $pgg_combine_edges_path -i IndexNewClusters < AllEdges > pgg.combined\n";}
	    `perl $pgg_combine_edges_path -i IndexNewClusters < AllEdges > pgg.combined 2>> $logfile`; # run pgg_combine_edges
	    die ("pgg.combined is zero size \n") unless (-s "pgg.combined");
	    &bash_error_check("perl $pgg_combine_edges_path -i IndexNewClusters < AllEdges > pgg.combined 2>> $logfile", $?, $!);
	    `rm *_alledges.txt`; # can remove these files now
	    `rm IndexNewClusters`;
	} else {
	    if ($debug) {print "\nperl $pgg_combine_edges_path < AllEdges > pgg.combined\n";}
	    `perl $pgg_combine_edges_path < AllEdges > pgg.combined 2>> $logfile`; # run pgg_combine_edges
	    die ("pgg.combined is zero size \n") unless (-s "pgg.combined");
	    &bash_error_check("perl $pgg_combine_edges_path < AllEdges > pgg.combined 2>> $logfile", $?, $!);
	    `rm *_alledges.txt`; # can remove these files now
	}
	if ($strip_version) {
	    if ($debug) {print "\nperl $pgg_multifasta_path -V -s $single_copy -B output -b multifasta -g $genome_list_path -m matchtable.col -a combined.att -p pgg.combined -M $medoids -A -S -R\n";}    # run pgg edge multi_fasta
	    `perl $pgg_multifasta_path -V -s $single_copy -B output -b multifasta -g $genome_list_path -m matchtable.col -a combined.att -p pgg.combined -M $medoids -T $topology_file -A -S -R >> $logfile 2>&1`;    # run pgg edge multi_fasta
	} else {
	    if ($debug) {print "\nperl $pgg_multifasta_path -s $single_copy -B output -b multifasta -g $genome_list_path -m matchtable.col -a combined.att -p pgg.combined -M $medoids -A -S -R\n";}    # run pgg edge multi_fasta
	    `perl $pgg_multifasta_path -s $single_copy -B output -b multifasta -g $genome_list_path -m matchtable.col -a combined.att -p pgg.combined -M $medoids -T $topology_file -A -S -R >> $logfile 2>&1`;    # run pgg edge multi_fasta
	}
	die ("output/pgg.txt is zero size \n") unless (-s "output/pgg.txt");
	&bash_error_check("perl $pgg_multifasta_path -s $single_copy -B output -b multifasta -g $genome_list_path -m matchtable.col -a combined.att -p pgg.combined -M $medoids -A -S -R >> $logfile 2>&1", $?, $!);
	
	$pgg = 'output/pgg.txt';
	if(compare("$pgg","$pgg_old") == 0)
	{
	    print "\nNo differences found in last iteration - PGG is stable!\n";
	    last;
	}
	else
	{
	    `paste $stats gene_ANI rearrange wgs_ANI > PGG_stats_$i.txt`;                  #add in all columns that contain their own header (new columns)
	    `mv output/pgg.txt pgg.txt`;                                                   # set the current iteration as "old"
	    `mv output/matchtable.txt matchtable.txt`;                                     # set the current iteration as "old"
	    `mv combined.att old.combined.att`;                                            # save a copy of attributes
	    `mv AllEdges old.AllEdges`;                                                    # save a copy of AllEdges
	    `mv pgg.combined old.pgg.combined`;                                            # save a copy of pgg.combined
	    `mv matchtable.col old.matchtable.col`;                                        # save a copy of matchtable.col
	    `mv output/medoids.fasta medoids.fasta`;
	    `mv output/single_copy_clusters.txt single_copy_clusters.txt`;
	    `mv output/cluster_sizes.txt cluster_sizes.txt`;
	    $weights = $cwd . "/cluster_sizes.txt";
	    $medoids = $cwd . "/medoids.fasta";                                                    # after first iteration, we want to use the medoids.fasta file, not the supplied medoids file
	    $single_copy = $cwd . "/single_copy_clusters.txt";
	    $matchtable = $cwd . "/matchtable.txt";                                                # After first iteration, we need to update location of matchtable and pgg files
	    $pgg = $cwd . "/pgg.txt";
	    if ($debug) {print "\nDifferences found in last iteration - PGG is not stable :-(\n";}
	}
	if ($debug) {print "Ending iteration $i\n\n";}
    }
    `rm *_topology.txt`;
    if ($debug) {print "Ending compute\n";}
}

############################################### main

{#main
    `echo "Starting" > $logfile`;
    if ($debug) {print "Starting ...\n\n";}
    if ($paralogs ne "") {
	&do_core_list;                                                                                 # run single_copy_core
    }
    `mkdir output`;                                                                                # first time - create necessary directories for pgg_edge_multifasta
    `mkdir multifasta`;
    &load_genomes;                                                                                 # read genome list (we only want to do this once, not each iteration)
    &read_topology;
    &compute;                                                                                      # for all genomes, run blast, run pgg_annotate, concatenate as we go using paste
}
                                                                       
