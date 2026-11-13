/* Overwatch's saved highlights (REC-53, 1.6.4).
 *
 * Overwatch saves a recorded highlight in its Documents\Overwatch\videos\overwatch
 * folder. In Recall's environment that is deep inside the hidden Library, where
 * players never find it, and Uninstall moves it to the Trash with everything else.
 * That folder becomes a link to the player's Movies › Overwatch, so saved clips land
 * where a Mac keeps videos, stay when Recall goes, and are what Recall's Highlights
 * window lists. Clips saved before are moved there.
 *
 * macOS asks before an app writes to Documents, Desktop or Downloads, not to Movies.
 * The home folder is NSHomeDirectory's (CFFIXED_USER_HOME in tests), never the
 * HOME Wine runs with, which is inside the data folder (wineEnv). */

static NSString *highlightsFolder(void) {
    return join(join(NSHomeDirectory(),@"Movies"),@"Overwatch");
}

/* The Windows profile Wine made: CrossOver's is "crossover"; anything but Public otherwise. */
static NSString *windowsProfile(void) {
    NSString *users=join(root,@"environment/drive_c/users");
    if([fm fileExistsAtPath:join(users,@"crossover")])return join(users,@"crossover");
    for(NSString *name in [[fm contentsOfDirectoryAtPath:users error:nil] sortedArrayUsingSelector:@selector(compare:)])
        if(![name isEqual:@"Public"] && ![name hasPrefix:@"."])return join(users,name);
    return nil;
}

/* A name in FOLDER that nothing has yet: "Clip.mp4", then "Clip 2.mp4" and so on. */
static NSString *freeName(NSString *folder, NSString *name) {
    NSString *path=join(folder,name),*stem=name.stringByDeletingPathExtension,*extension=name.pathExtension;
    for(int i=2;[fm fileExistsAtPath:path] || [fm destinationOfSymbolicLinkAtPath:path error:nil];++i)
        path=join(folder,extension.length ? [NSString stringWithFormat:@"%@ %d.%@",stem,i,extension]
                                          : [NSString stringWithFormat:@"%@ %d",stem,i]);
    return path;
}

/* Never fatal: Overwatch saves into its own folder as before if anything here fails. */
static void configureHighlights(void) {
    NSString *profile=windowsProfile(),*target=highlightsFolder();
    if(!profile)return;
    NSString *videos=join(profile,@"Documents/Overwatch/videos"),*link=join(videos,@"overwatch");
    NSError *error=nil;
    if(![fm createDirectoryAtPath:target withIntermediateDirectories:YES attributes:nil error:&error]) {
        event(@"highlights_folder_unavailable",@{@"folder":target,@"reason":error.localizedDescription ?: @""});
        return;
    }
    struct stat st;
    if(!lstat(link.fileSystemRepresentation,&st)) {
        if(S_ISLNK(st.st_mode)) {
            if([[fm destinationOfSymbolicLinkAtPath:link error:nil] isEqual:target])return;
            // A link left from before (another home or folder name) points here instead.
            if(unlink(link.fileSystemRepresentation))return;
        } else if(S_ISDIR(st.st_mode)) {
            NSUInteger moved=0;
            for(NSString *name in [fm contentsOfDirectoryAtPath:link error:nil]) {
                if([name isEqual:@".DS_Store"]) {[fm removeItemAtPath:join(link,name) error:nil];continue;}
                if(![fm moveItemAtPath:join(link,name) toPath:freeName(target,name) error:&error]) {
                    event(@"highlights_folder_unavailable",@{@"folder":target,@"reason":error.localizedDescription ?: @""});
                    return;
                }
                moved++;
            }
            // Only an empty folder goes; rmdir refuses anything else.
            if(rmdir(link.fileSystemRepresentation))return;
            if(moved)event(@"highlights_moved",@{@"count":@(moved),@"folder":target});
        } else return;  // a file of that name is not ours to replace
    } else mkdirs(videos);
    if(![fm createSymbolicLinkAtPath:link withDestinationPath:target error:&error])
        event(@"highlights_folder_unavailable",@{@"folder":target,@"reason":error.localizedDescription ?: @""});
}
