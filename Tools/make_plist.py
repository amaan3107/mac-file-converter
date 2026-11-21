# Generates Info.plist (app metadata + Finder right-click actions).
import plistlib, sys

IMAGES, PDF, MOVIES, AUDIO = ["public.image"], ["com.adobe.pdf"], ["public.movie"], ["public.audio"]
DOCS = ["public.rtf", "com.apple.rtfd", "public.plain-text", "public.html",
        "org.openxmlformats.wordprocessingml.document", "com.microsoft.word.doc",
        "org.oasis-open.opendocument.text"]

def service(title, message, types, user_data=None):
    s = {"NSMenuItem": {"default": title}, "NSMessage": message, "NSPortName": "The Converter",
         "NSRequiredContext": {}, "NSSendFileTypes": types}
    if user_data: s["NSUserData"] = user_data
    return s

plist = {
    "CFBundleName": "The Converter", "CFBundleDisplayName": "The Converter",
    "CFBundleIdentifier": "local.theconverter.app", "CFBundleExecutable": "TheConverter",
    "CFBundleIconFile": "AppIcon", "CFBundlePackageType": "APPL",
    "CFBundleShortVersionString": "1.1", "CFBundleVersion": "2",
    "LSMinimumSystemVersion": "14.0", "NSHighResolutionCapable": True,
    "LSApplicationCategoryType": "public.app-category.utilities",
    "CFBundleDocumentTypes": [{
        "CFBundleTypeName": "Convertible File", "CFBundleTypeRole": "Viewer", "LSHandlerRank": "Alternate",
        "LSItemContentTypes": IMAGES + MOVIES + AUDIO + PDF + DOCS,
    }],
    "NSServices": [
        service("Convert with The Converter", "convertFiles", IMAGES + MOVIES + AUDIO + PDF + DOCS),
        service("Convert to JPG", "quickConvert", IMAGES + PDF, "jpg"),
        service("Convert to PDF", "quickConvert", IMAGES + DOCS, "pdf"),
        service("Combine into PDF", "combineToPDF", IMAGES + PDF + DOCS),
        service("Convert to MP4", "quickConvert", MOVIES, "mp4"),
        service("Convert to MP3", "quickConvert", AUDIO + MOVIES, "mp3"),
    ],
}
with open(sys.argv[1], "wb") as f:
    plistlib.dump(plist, f)
