package com.safe.app;
import android.preference.PreferenceActivity;
public class Settings extends PreferenceActivity {
protected boolean isValidFragment(String n){ return "com.safe.app.AllowedFrag".equals(n); }
}
